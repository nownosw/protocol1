// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";
import {IChainlinkAggregator} from "tests/interfaces/external/IChainlinkAggregator.sol";
import {IERC20} from "tests/interfaces/external/IERC20.sol";
import {ILidoSteth} from "tests/interfaces/external/ILidoSteth.sol";

contract ChainlinkLikeWstethPriceFeedTest is IntegrationTest {
    IChainlinkAggregator wstethAggregator;
    IChainlinkAggregator originalStethEthAggregator = IChainlinkAggregator(ETHEREUM_STETH_ETH_AGGREGATOR);

    function setUp() public override {
        vm.createSelectFork("mainnet", ETHEREUM_BLOCK_LATEST);

        wstethAggregator = __deployWstethAggregator();
    }

    // DEPLOYMENT HELPERS

    function __deployWstethAggregator() private returns (IChainlinkAggregator wstethAggregator_) {
        bytes memory args = abi.encode(ETHEREUM_STETH, ETHEREUM_STETH_ETH_AGGREGATOR);

        address addr = deployCode("ChainlinkLikeWstethPriceFeed.sol", args);

        return IChainlinkAggregator(addr);
    }

    // TESTS

    function test_decimals_success() public {
        assertEq(wstethAggregator.decimals(), CHAINLINK_AGGREGATOR_DECIMALS_ETH, "Incorrect decimals");
    }

    function test_latestRoundData_successWithForkData() public {
        // Query return data of stETH/ETH aggregator and the simulated wstETH/ETH aggregator
        (,, uint256 originalStartedAt, uint256 originalUpdatedAt,) = originalStethEthAggregator.latestRoundData();
        (
            uint80 wstethRoundId,
            int256 wstethAnswer,
            uint256 wstethStartedAt,
            uint256 wstethUpdatedAt,
            uint80 wstethAnsweredInRound
        ) = wstethAggregator.latestRoundData();

        // startedAt and updatedAt should be passed-through as-is
        assertEq(wstethStartedAt, originalStartedAt, "Incorrect startedAt");
        assertEq(wstethUpdatedAt, originalUpdatedAt, "Incorrect updatedAt");

        // Round values should be empty
        assertEq(wstethRoundId, 0, "Non-zero roundId");
        assertEq(wstethAnsweredInRound, 0, "Non-zero roundData");

        // Rate: 1.17 ETH/wstETH, on June 24th, 2024
        // https://www.coingecko.com/en/coins/wrapped-steth
        uint256 expectedWstethEthRate = 1.17e18;
        uint256 halfPercent = WEI_ONE_PERCENT / 2;
        assertApproxEqRel(uint256(wstethAnswer), expectedWstethEthRate, halfPercent, "Incorrect rate");
    }

    function test_latestRoundData_successWithAlteredRates() public {
        // Mock return values of stETH and wstETH sources to be:
        // - eth-per-steth rate is 5e18
        // - steth-per-wsteth rate is 2e18
        // Expected eth-per-wsteth rate: 10e18
        uint256 ethPerStethRate = 5e18;
        uint256 stethPerWstethRate = 2e18;
        uint256 expectedEthPerWstethRate = 10e18;

        // Mock call on the Chainlink aggregator
        vm.mockCall({
            callee: address(originalStethEthAggregator),
            data: abi.encodeWithSelector(IChainlinkAggregator.latestRoundData.selector),
            returnData: abi.encode(1, ethPerStethRate, 345, 456, 2)
        });

        // Mock call in stETH
        vm.mockCall({
            callee: ETHEREUM_STETH,
            data: abi.encodeWithSelector(ILidoSteth.getPooledEthByShares.selector, assetUnit(IERC20(ETHEREUM_WSTETH))),
            returnData: abi.encode(stethPerWstethRate)
        });

        (, int256 wstethAnswer,,,) = wstethAggregator.latestRoundData();
        assertEq(uint256(wstethAnswer), expectedEthPerWstethRate, "Incorrect rate");
    }
}
