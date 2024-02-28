/// @author raffy.eth
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ECDSA} from "@openzeppelin/contracts@4.8.2/utils/cryptography/ECDSA.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ENS} from "@ensdomains/ens-contracts/contracts/registry/ENS.sol";
import {IExtendedResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/IExtendedResolver.sol";
import {IExtendedDNSResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/IExtendedDNSResolver.sol";
import {IAddrResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/IAddrResolver.sol";
import {IAddressResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/IAddressResolver.sol";
import {ITextResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/ITextResolver.sol";
import {IPubkeyResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {IContentHashResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IMulticallable} from "@ensdomains/ens-contracts/contracts/resolvers/IMulticallable.sol";
import {BytesUtils} from "@ensdomains/ens-contracts/contracts/wrapper/BytesUtils.sol";
import {HexUtils} from "@ensdomains/ens-contracts/contracts/utils/HexUtils.sol";

error OffchainLookup(address from, string[] urls, bytes request, bytes4 callback, bytes carry);

interface IOnchainResolver {
	function onchain(bytes32 node) external view returns (bool);
	event OnchainChanged(bytes32 indexed node, bool on);
}

interface IHybridResolver {
	function hybridize(bytes calldata request, uint256 style);
}

contract TheOffchainResolver is IERC165, ITextResolver, IAddrResolver, IAddressResolver, IPubkeyResolver, IContentHashResolver, IMulticallable, IExtendedResolver, IExtendedDNSResolver, IOnchainResolver {
	using BytesUtils for bytes;
	using HexUtils for bytes;

	error Unauthorized(address owner); // not operator of node
	error InvalidContext(bytes context); // context too short or invalid signer
	error Unreachable(bytes name);
	error CCIPReadExpired(uint256 t); // ccip response is stale
	error CCIPReadUntrusted(address signed, address expect);
	error NodeCheck(bytes32 node);

	address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
	uint256 constant COIN_TYPE_ETH = 60;
	uint256 constant COIN_TYPE_FALLBACK = 0xb32cdf4d3c016cb0f079f205ad61c36b1a837fb3e95c70a94bdedfca0518a010; // https://adraffy.github.io/keccak.js/test/demo.html#algo=keccak-256&s=fallback&escape=1&encoding=utf8

	function supportsInterface(bytes4 x) external pure returns (bool) {
		return x == type(IERC165).interfaceId
			|| x == type(ITextResolver).interfaceId
			|| x == type(IAddrResolver).interfaceId
			|| x == type(IAddressResolver).interfaceId
			|| x == type(IPubkeyResolver).interfaceId
			|| x == type(IContentHashResolver).interfaceId
			|| x == type(IMulticallable).interfaceId
			|| x == type(IExtendedResolver).interfaceId
			|| x == type(IExtendedDNSResolver).interfaceId
			|| x == type(IOnchainResolver).interfaceId
			|| x == 0x73302a25; // https://adraffy.github.io/keccak.js/test/demo.html#algo=evm&s=ccip.context&escape=1&encoding=utf8
	}

	// utils
	modifier requireOperator(bytes32 node) {
		address owner = ENS(ENS_REGISTRY).owner(node);
		if (owner != msg.sender && !ENS(ENS_REGISTRY).isApprovedForAll(owner, msg.sender)) revert Unauthorized(owner);
		_;
	}
	function slotForCoin(bytes32 node, uint256 cty) internal pure returns (uint256) {
		return uint256(keccak256(abi.encodeCall(IAddressResolver.addr, (node, cty))));
	}
	function slotForText(bytes32 node, string memory key) internal pure returns (uint256) {
		return uint256(keccak256(abi.encodeCall(ITextResolver.text, (node, key))));
	}
	function slotForSelector(bytes4 selector, bytes32 node) internal pure returns (uint256) {
		return uint256(keccak256(abi.encodeWithSelector(selector, node)));
	}

	// getters (structured)
	function addr(bytes32 node) external view returns (address payable a) {
		(bytes32 extnode, address resolver) = determineExternalFallback(node);
		if (resolver != address(0) && IERC165(resolver).supportsInterface(type(IAddrResolver).interfaceId)) {
			a = IAddrResolver(resolver).addr(extnode);
		}
		if (a == address(0)) {
			a = payable(address(bytes20(getTiny(slotForCoin(node, COIN_TYPE_ETH)))));
		}
	}
	function pubkey(bytes32 node) external view returns (bytes32 x, bytes32 y) {
		(bytes32 extnode, address resolver) = determineExternalFallback(node);
		if (resolver != address(0) && IERC165(resolver).supportsInterface(type(IPubkeyResolver).interfaceId)) {
			(x, y) = IPubkeyResolver(resolver).pubkey(extnode);
		}
		if (x == 0 && y == 0) {
			bytes memory v = getTiny(slotForSelector(IPubkeyResolver.pubkey.selector, node));
			if (v.length == 64) (x, y) = abi.decode(v, (bytes32, bytes32));
		}
	}

	// getters (bytes-like)
	function addr(bytes32, uint256) external view returns (bytes memory) {
		return reflectGetBytes(msg.data);
	}
	function text(bytes32, string calldata) external view returns (string memory) {
		return string(reflectGetBytes(msg.data));
	}
	function contenthash(bytes32) external view returns (bytes memory) {
		return reflectGetBytes(msg.data);
	}
	function reflectGetBytes(bytes memory request) internal view returns (bytes memory) {
		bytes32 node;
		assembly { node := mload(add(request, 36)) }
		uint256 slot = uint256(keccak256(request)); // hash before we mangle
		(bytes32 extnode, address resolver) = determineExternalFallback(node);
		if (resolver != address(0)) {
			assembly { mstore(add(request, 36), extnode) } // mangled
			(bool ok, bytes memory v) = resolver.staticcall(request);
			if (ok && abi.decode(v, (bytes)).length != 0) {
				return v;
			}
		}
		return getTiny(slot);
	}

	// TOR helpers
	function parseContext(bytes memory v) internal pure returns (string[] memory urls, address signer) {
		// {SIGNER} {ENDPOINT}
		// "0x51050ec063d393217B436747617aD1C2285Aeeee http://a" => (2 + 40 + 1 + 8)
		if (v.length < 51) revert InvalidContext(v);
		bool valid;
		(signer, valid) = v.hexToAddress(2, 42); // unchecked 0x-prefix
		if (!valid) revert InvalidContext(v);
		assembly {
			let size := mload(v)
			v := add(v, 43) // drop address
			mstore(v, sub(size, 43))
		}
		urls = new string[](1); // TODO: support multiple URLs
		urls[0] = string(v);
	}
	function findSelf(bytes memory name) internal view returns (bytes32 node, uint256 offset) {
		unchecked {
			while (true) {
				node = name.namehash(offset);
				if (ENS(ENS_REGISTRY).resolver(node) == address(this)) break;
				uint256 size = uint256(uint8(name[offset]));
				if (size == 0) revert Unreachable(name);
				offset += 1 + size;
			}
		}
	}
	function verify(bytes calldata ccip, bytes memory carry) internal view returns (bytes memory, bytes memory) {
		(bytes memory sig, uint64 expires, bytes memory response) = abi.decode(ccip, (bytes, uint64, bytes));
		if (expires < block.timestamp) revert CCIPReadExpired(expires);
		(bytes memory request, address signer) = abi.decode(carry, (bytes, address));
		bytes32 hash = keccak256(abi.encodePacked(address(this), expires, keccak256(request), keccak256(response)));
		address signed = ECDSA.recover(hash, sig);
		if (signed != signer) revert CCIPReadUntrusted(signed, signer);
		return (request, response);
	}

	// IExtendedDNSResolver
	function resolve(bytes calldata name, bytes calldata data, bytes calldata context) external view returns (bytes memory) {
		(string[] memory urls, address signer) = parseContext(context);
		bytes memory request = abi.encodeWithSelector(IExtendedResolver.resolve.selector, name, data);
		revert OffchainLookup(address(this), urls, request, this.buggedCallback.selector, abi.encode(abi.encode(request, signer), address(this)));
	}
	function buggedCallback(bytes calldata response, bytes calldata buggedExtraData) external view returns (bytes memory v) {
		(, v) = verify(response, abi.decode(buggedExtraData, (bytes)));
	}

	// IExtendedResolver
	function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory result) {
		unchecked {
			bytes32 node = name.namehash(0);
			if (bytes4(data) == IMulticallable.multicall.selector) {
				bytes[] memory a = abi.decode(data[4:], (bytes[]));
				bytes[] memory b = new bytes[](a.length);
				bool off;
				for (uint256 i = 0; i < a.length; i += 1) {
					bytes memory v = getEncodedFallbackValue(a[i]);
					if (v.length == 0) {
						off = true; // one record is missing, go offchain
						break;
					}
					b[i] = v;
				}
				if (!off || onchain(node)) return abi.encode(b);
			} else {
				bytes memory v = getEncodedFallbackValue(data);
				if (v.length > 0 || onchain(node)) return v;
			}
			(bytes32 node0, ) = findSelf(name);
			(string[] memory urls, address signer) = parseContext(getTiny(slotForText(node0, "ccip.context")));
			bytes memory request = abi.encodeWithSelector(IExtendedResolver.resolve.selector, name, data);
			revert OffchainLookup(address(this), urls, request, this.ensCallback.selector, abi.encode(request, signer));
		}
	}
	function ensCallback(bytes calldata ccip, bytes calldata carry) external view returns (bytes memory) {
		unchecked {
			(bytes memory request, bytes memory response) = verify(ccip, carry);
			assembly {
				mstore(add(request, 4), sub(mload(request), 4)) // trim resolve() selector
				request := add(request, 4)
			}
			(, bytes memory data) = abi.decode(request, (bytes, bytes));
			if (bytes4(data) == IMulticallable.multicall.selector) {
				assembly {
					mstore(add(data, 4), sub(mload(data), 4)) // trim selector
					data := add(data, 4)
				}
				bytes[] memory a = abi.decode(data, (bytes[]));
				bytes[] memory b = abi.decode(response, (bytes[]));
				for (uint256 i; i < a.length; i += 1) {
					bytes memory v = getEncodedFallbackValue(a[i]);
					if (v.length != 0) b[i] = v;
				}
				response = abi.encode(b);
			}
			return response;
		}
	}
	function determineExternalFallback(bytes32 node) internal view returns (bytes32 extnode, address resolver) {
		bytes memory v = getTiny(slotForCoin(node, COIN_TYPE_FALLBACK));
		if (v.length == 20) { // its a resolver
			extnode = node;
			resolver = address(bytes20(v));
		} else {
			if (v.length == 32) { // its a nodehash 
				extnode = bytes32(v);
			} else { // assume derived: namehash("_" + node)
				// https://adraffy.github.io/keccak.js/test/demo.html#algo=keccak-256&s=_&escape=1&encoding=utf8
				extnode = keccak256(abi.encode(node, 0xcd5edcba1904ce1b09e94c8a2d2a85375599856ca21c793571193054498b51d7));
			}
			resolver = ENS(ENS_REGISTRY).resolver(extnode);
		}
	}
	function getEncodedFallbackValue(bytes memory request) internal view returns (bytes memory encoded) {
		(bool ok, bytes memory v) = address(this).staticcall(request);
		if (ok && !isNullAssumingPadded(v)) {
			// unfortunately it is impossible to determine if an arbitrary abi-encoded response is null
			// abi.encode('') = 0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000
			// https://adraffy.github.io/keccak.js/test/demo.html#algo=keccak-256&s=0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000&escape=1&encoding=hex
			if (keccak256(v) != 0x569e75fc77c1a856f6daaf9e69d8a9566ca34aa47f9133711ce065a571af0cfd) {
				encoded = v;
			}
		}
	}
	function isNullAssumingPadded(bytes memory v) internal pure returns (bool) {
		assembly {
			let p := add(v, 32)
			let e := add(p, mload(v))
			for {} lt(p, e) { p := add(p, 32) } {
				if iszero(iszero(mload(p))) { // != 0
					return(0, 32) // return false
				}
			}
		}
		return true;
	}

	// multicall
	// TODO: allow ccip-read through this mechanism too
	function multicall(bytes[] calldata calls) external returns (bytes[] memory) {
		return _multicall(0, calls);
	}
	function multicallWithNodeCheck(bytes32 nodehash, bytes[] calldata calls) external returns (bytes[] memory) {
		return _multicall(nodehash, calls);
	}
	function _multicall(bytes32 node, bytes[] calldata calls) internal returns (bytes[] memory answers) {
		unchecked {
			answers = new bytes[](calls.length);
			for (uint256 i; i < calls.length; i += 1) {
				if (node != 0) {
					bytes32 check = bytes32(calls[i][4:36]);
					if (check != node) revert NodeCheck(check);
				}
				(bool ok, bytes memory v) = address(this).delegatecall(calls[i]);
				require(ok);
				answers[i] = v;
			}
		}
	}

	// setters
	function setAddr(bytes32 node, address a) external {
		setAddr(node, COIN_TYPE_ETH, a == address(0) ? bytes('') : abi.encodePacked(a));
	}
	function setAddr(bytes32 node, uint256 cty, bytes memory v) requireOperator(node) public {
		setTiny(slotForCoin(node, cty), v);
		emit AddressChanged(node, cty, v);
		if (cty == COIN_TYPE_ETH) emit AddrChanged(node, address(bytes20(v)));
	}
	function setText(bytes32 node, string calldata key, string calldata s) requireOperator(node) external {
		setTiny(slotForText(node, key), bytes(s));
		emit TextChanged(node, key, key, s);
	}
	function setContenthash(bytes32 node, bytes calldata v) requireOperator(node) external {
		setTiny(slotForSelector(IContentHashResolver.contenthash.selector, node), v);
		emit ContenthashChanged(node, v);
	}
	function setPubkey(bytes32 node, bytes32 x, bytes32 y) requireOperator(node) external {
		setTiny(slotForSelector(IPubkeyResolver.pubkey.selector, node), x == 0 && y == 0 ? bytes('') : abi.encode(x, y));
		emit PubkeyChanged(node, x, y);
	}

	// IOnchainResolver
	function toggleOnchain(bytes32 node, address resolver) requireOperator(node) external {
		uint256 slot = slotForSelector(IOnchainResolver.onchain.selector, node);
		bool on;
		assembly { 
			on := iszero(sload(slot))
			sstore(slot, on)
		}
		emit OnchainChanged(node, on);
	}
	function onchain(bytes32 node) public view returns (bool) {		
		uint256 slot = slotForSelector(IOnchainResolver.onchain.selector, node);
		assembly { slot := sload(slot) }
		return slot != 0;
	}
	
	// ************************************************************
	// TinyKV.sol: https://github.com/adraffy/TinyKV.sol

	// header: first 4 bytes
	// [00000000_00000000000000000000000000000000000000000000000000000000] // null (0 slot)
	// [00000000_00000000000000000000000000000000000000000000000000000001] // empty (1 slot, hidden)
	// [00000001_XX000000000000000000000000000000000000000000000000000000] // 1 byte (1 slot)
	// [0000001C_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX] // 28 bytes (1 slot
	// [0000001D_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX][XX000000...] // 29 bytes (2 slots)
	function tinySlots(uint256 size) internal pure returns (uint256) {
		unchecked {
			return size != 0 ? (size + 35) >> 5 : 0; // ceil((4 + size) / 32)
		}
	}
	function setTiny(uint256 slot, bytes memory v) internal {
		unchecked {
			uint256 head;
			assembly { head := sload(slot) }
			uint256 size;
			assembly { size := mload(v) }
			uint256 n0 = tinySlots(head >> 224);
			uint256 n1 = tinySlots(size);
			assembly {
				// overwrite
				if gt(n1, 0) {
					sstore(slot, or(shl(224, size), shr(32, mload(add(v, 32)))))
					let ptr := add(v, 60)
					for { let i := 1 } lt(i, n1) { i := add(i, 1) } {
						sstore(add(slot, i), mload(ptr))
						ptr := add(ptr, 32)
					}
				}
				// clear unused
				for { let i := n1 } lt(i, n0) { i := add(i, 1) } {
					sstore(add(slot, i), 0)
				}
			}
		}
	}
	function getTiny(uint256 slot) internal view returns (bytes memory v) {
		unchecked {
			uint256 head;
			assembly { head := sload(slot) }
			uint256 size = head >> 224;
			if (size != 0) {
				v = new bytes(size);
				uint256 n = tinySlots(size);
				assembly {
					mstore(add(v, 32), shl(32, head))
					let p := add(v, 60)
					for { let i := 1 } lt(i, n) { i := add(i, 1) } {
						mstore(p, sload(add(slot, i)))
						p := add(p, 32)
					}
				}
			}
		}
	}

}
