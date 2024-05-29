// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0 <0.9.0;

interface IUniswapV2Pair {
    function token0() external view returns (address token0Address_);

    function token1() external view returns (address token1Address_);
}
