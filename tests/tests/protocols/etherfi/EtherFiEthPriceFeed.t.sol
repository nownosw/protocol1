// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IChainlinkPriceFeedMixin as IChainlinkPriceFeedMixinProd} from
    "contracts/release/infrastructure/price-feeds/primitives/IChainlinkPriceFeedMixin.sol";

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {IERC20} from "tests/interfaces/external/IERC20.sol";

import {IEtherFiEthPriceFeed} from "tests/interfaces/internal/IEtherFiEthPriceFeed.sol";
import {IValueInterpreter} from "tests/interfaces/internal/IValueInterpreter.sol";

address constant ETHERFI_ETH_ADDRESS = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
address constant WRAPPED_ETHERFI_ETH_ADDRESS = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
address constant WRAPPED_ETHERFI_ETH_AGGREGATOR = 0x8751F736E94F6CD167e8C5B97E245680FbD9CC36;
uint256 constant WRAPPED_ETHERFI_ETH_CREATION_BLOCK_TIMESTAMP = 1689005159;
uint256 constant MINIMUM_REQUIRED_BLOCK_FOR_WEETH_AGGREGATOR = 18827300;

abstract contract EtherFiEthPriceFeedTestBase is IntegrationTest {
    IEtherFiEthPriceFeed internal priceFeed;

    EnzymeVersion internal version;

    function __initialize(EnzymeVersion _version) internal {
        setUpMainnetEnvironment(
            ETHEREUM_BLOCK_LATEST < MINIMUM_REQUIRED_BLOCK_FOR_WEETH_AGGREGATOR
                ? MINIMUM_REQUIRED_BLOCK_FOR_WEETH_AGGREGATOR
                : ETHEREUM_BLOCK_LATEST
        );
        version = _version;
        priceFeed = __deployPriceFeed();
    }

    function __renitialize(uint256 _forkBlock) private {
        setUpMainnetEnvironment(_forkBlock);
        priceFeed = __deployPriceFeed();
    }

    // DEPLOYMENT HELPERS

    function __deployPriceFeed() private returns (IEtherFiEthPriceFeed) {
        address addr =
            deployCode("EtherFiEthPriceFeed.sol", abi.encode(ETHERFI_ETH_ADDRESS, WRAPPED_ETHERFI_ETH_ADDRESS));
        return IEtherFiEthPriceFeed(addr);
    }

    function __deploySimulatedAggregator(
        address _originalAggregatorAddress,
        IChainlinkPriceFeedMixinProd.RateAsset _rateAsset
    ) private returns (address aggregator_) {
        bytes memory args = abi.encode(_originalAggregatorAddress, _rateAsset);
        return deployCode("NonStandardPrecisionSimulatedAggregator.sol", args);
    }

    // MISC HELPERS

    function __addDerivativeAndUnderlying() private {
        addPrimitive({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: WRAPPED_ETHERFI_ETH_ADDRESS,
            _skipIfRegistered: true,
            _aggregatorAddress: __deploySimulatedAggregator({
                _originalAggregatorAddress: WRAPPED_ETHERFI_ETH_AGGREGATOR,
                _rateAsset: IChainlinkPriceFeedMixinProd.RateAsset.ETH
            }),
            _rateAsset: IChainlinkPriceFeedMixinProd.RateAsset.ETH
        });
        addDerivative({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: ETHERFI_ETH_ADDRESS,
            _skipIfRegistered: true,
            _priceFeedAddress: address(priceFeed)
        });
    }

    // TESTS

    function test_calcUnderlyingValuesForSpecificBlock_success() public {
        __renitialize(20139200); // roll the fork block, and re-deploy

        __addDerivativeAndUnderlying();

        assertValueInUSDForVersion({
            _version: version,
            _asset: ETHERFI_ETH_ADDRESS,
            _amount: assetUnit(IERC20(ETHERFI_ETH_ADDRESS)),
            _expected: 3772086445223782594543 // 3772.086445223782594543 USD
        });
    }

    function test_calcUnderlyingValuesInvariant_success() public {
        __addDerivativeAndUnderlying();

        uint256 value = IValueInterpreter(getValueInterpreterAddressForVersion(version)).calcCanonicalAssetValue({
            _baseAsset: ETHERFI_ETH_ADDRESS,
            _amount: assetUnit(IERC20(ETHERFI_ETH_ADDRESS)),
            _quoteAsset: WRAPPED_ETHERFI_ETH_ADDRESS
        });

        uint256 underlyingSingleUnit = assetUnit(IERC20(WRAPPED_ETHERFI_ETH_ADDRESS));
        uint256 timePassed = block.timestamp - WRAPPED_ETHERFI_ETH_CREATION_BLOCK_TIMESTAMP;
        uint256 maxDeviationPer365DaysInBps = 7 * BPS_ONE_PERCENT;

        assertGt(value, underlyingSingleUnit, "Value too low");
        assertLe(
            value,
            underlyingSingleUnit
                + (underlyingSingleUnit * maxDeviationPer365DaysInBps * timePassed) / (365 days * BPS_ONE_HUNDRED_PERCENT),
            "Deviation too high"
        );
    }

    function test_isSupportedAsset_success() public {
        assertTrue(priceFeed.isSupportedAsset({_asset: ETHERFI_ETH_ADDRESS}), "Unsupported asset");
    }

    function test_isSupportedAsset_successWithUnsupportedAsset() public {
        assertFalse(priceFeed.isSupportedAsset({_asset: makeAddr("RandomToken")}), "Incorrectly supported asset");
    }
}

contract EtherFiEthPriceFeedTestEthereum is EtherFiEthPriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.Current);
    }
}

contract EtherFiEthPriceFeedTestEthereumV4 is EtherFiEthPriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.V4);
    }
}
