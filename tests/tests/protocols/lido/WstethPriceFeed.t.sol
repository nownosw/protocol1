// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IChainlinkPriceFeedMixin as IChainlinkPriceFeedMixinProd} from
    "contracts/release/infrastructure/price-feeds/primitives/IChainlinkPriceFeedMixin.sol";

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {IERC20} from "tests/interfaces/external/IERC20.sol";
import {ILidoSteth} from "tests/interfaces/external/ILidoSteth.sol";

import {IFundDeployer} from "tests/interfaces/internal/IFundDeployer.sol";
import {IValueInterpreter} from "tests/interfaces/internal/IValueInterpreter.sol";
import {IWstethPriceFeed} from "tests/interfaces/internal/IWstethPriceFeed.sol";

abstract contract WstethPriceFeedTestBase is IntegrationTest {
    IWstethPriceFeed internal priceFeed;

    EnzymeVersion internal version;

    function __initialize(EnzymeVersion _version) internal {
        version = _version;
        setUpMainnetEnvironment();
        priceFeed = __deployPriceFeed();
    }

    function __renitialize(uint256 _forkBlock) private {
        setUpMainnetEnvironment(_forkBlock);
        priceFeed = __deployPriceFeed();
    }

    // DEPLOYMENT HELPERS

    function __deployPriceFeed() private returns (IWstethPriceFeed priceFeed_) {
        address addr = deployCode("WstethPriceFeed.sol", abi.encode(ETHEREUM_WSTETH, ETHEREUM_STETH));
        return IWstethPriceFeed(addr);
    }

    // MISC HELPERS

    function __addDerivativeAndUnderlying() private {
        addPrimitive({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: ETHEREUM_STETH,
            _skipIfRegistered: true,
            _aggregatorAddress: ETHEREUM_STEH_ETH_AGGREGATOR,
            _rateAsset: IChainlinkPriceFeedMixinProd.RateAsset.ETH
        });
        addDerivative({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: ETHEREUM_WSTETH,
            _skipIfRegistered: true,
            _priceFeedAddress: address(priceFeed)
        });
    }

    // TESTS

    function test_calcUnderlyingValuesForSpecificBlock_success() public {
        __renitialize(18050000); // roll the fork block, and re-deploy

        __addDerivativeAndUnderlying();

        assertValueInUSDForVersion({
            _version: version,
            _asset: ETHEREUM_WSTETH,
            _amount: assetUnit(IERC20(ETHEREUM_WSTETH)),
            _expected: 1864247628417228432384 // 1864.247628417228432384 USD
        });
    }

    function test_calcUnderlyingValuesStETHInvariant_success() public {
        __addDerivativeAndUnderlying();

        uint256 value = IValueInterpreter(getValueInterpreterAddressForVersion(version)).calcCanonicalAssetValue({
            _baseAsset: ETHEREUM_WSTETH,
            _amount: assetUnit(IERC20(ETHEREUM_WSTETH)),
            _quoteAsset: ETHEREUM_STETH
        });

        // 1 WSTETH value must be always greater than 1 stETH
        assertGt(value, assetUnit(IERC20(ETHEREUM_STETH)), "Incorrect value");
    }

    function test_isSupportedAsset_success() public {
        assertTrue(priceFeed.isSupportedAsset({_asset: ETHEREUM_WSTETH}), "Unsupported token");
    }
}

contract WstethPriceFeedTestEthereum is WstethPriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.Current);
    }
}

contract WstethPriceFeedTestEthereumV4 is WstethPriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.V4);
    }
}
