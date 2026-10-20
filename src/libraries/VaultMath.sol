// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library VaultMath {
    uint256 internal constant RAY = 1e27;

    /// @dev Full precision floor(x*y/d). Algorithm from OpenZeppelin Math (MIT), based on
    /// Remco Bloemen's mulDiv and Uniswap FullMath. See docs/THIRD_PARTY.md.
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 lo;
            uint256 hi;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                lo := mul(x, y)
                hi := sub(sub(mm, lo), lt(mm, lo))
            }
            if (hi == 0) return lo / d;
            require(d > hi, "mulDiv overflow");
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, d)
                hi := sub(hi, gt(remainder, lo))
                lo := sub(lo, remainder)
            }
            uint256 twos = d & (0 - d);
            assembly ("memory-safe") {
                d := div(d, twos)
                lo := div(lo, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            lo |= hi * twos;
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            result = lo * inv;
        }
    }

    /// @dev exp(-seconds / (100 days)), evaluated on integer seconds with 27-digit precision.
    /// The base is floor(exp(-1/8640000) * 1e27). Anchored evaluation prevents checkpoint-frequency
    /// dependence. Products are <= 1e54, and exponentiation takes at most 256 iterations.
    function decay(uint256 seconds_) internal pure returns (uint256 z) {
        uint256 x = 999999884259265957218534458;
        z = RAY;
        while (seconds_ != 0) {
            if (seconds_ & 1 != 0) z = z * x / RAY;
            seconds_ >>= 1;
            if (seconds_ != 0) x = x * x / RAY;
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
