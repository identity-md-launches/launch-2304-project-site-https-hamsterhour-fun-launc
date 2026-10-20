// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMD oracle v2 attestation, as a consumer hashes it
/// @notice Field order, type string and domain name follow IMD's published oracle reference
/// (imd.fun/docs, "The attestation"). The struct hash is encoded in two halves because sixteen
/// words in one abi.encode is too deep for the legacy code generator; every member is a static
/// 32-byte word so the concatenation is byte for byte the EIP-712 encoding.
library OracleAttestation {
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    uint8 internal constant ANSWER_UINT256 = 3;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("IdentityMD Oracle");
    bytes32 internal constant VERSION_HASH = keccak256("2");

    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    function hashStruct(Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }

    /// @notice EIP-712 digest of `a` in the domain of `consumer` on `chainId`.
    function digest(Attestation calldata a, uint256 chainId, address consumer) internal pure returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, consumer));
        return keccak256(abi.encodePacked(hex"1901", domain, hashStruct(a)));
    }

    /// @notice Recovers an EOA signer from a 65-byte (r, s, v) signature; zero on any malformed input.
    function recover(bytes32 hash, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v != 27 && v != 28) return address(0);
        // Reject high-s signatures so each digest has one canonical signature (EIP-2).
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(hash, v, r, s);
    }
}
