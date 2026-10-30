// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library WadRayMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = WAD / 2;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = RAY / 2;

    uint256 internal constant WAD_RAY_RATIO = 1e9;

    function _ray() internal pure returns (uint256) {
        return RAY;
    }

    function _wad() internal pure returns (uint256) {
        return WAD;
    }

    function _halfRay() internal pure returns (uint256) {
        return HALF_RAY;
    }

    function _halfWad() internal pure returns (uint256) {
        return HALF_WAD;
    }

    function _wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;

        return (a * b + HALF_WAD) / WAD;
    }
}
