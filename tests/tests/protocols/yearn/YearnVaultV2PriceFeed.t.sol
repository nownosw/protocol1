// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IChainlinkPriceFeedMixin as IChainlinkPriceFeedMixinProd} from
    "contracts/release/infrastructure/price-feeds/primitives/IChainlinkPriceFeedMixin.sol";

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {IERC20} from "tests/interfaces/external/IERC20.sol";
import {IYearnVaultV2Vault} from "tests/interfaces/external/IYearnVaultV2Vault.sol";

import {IFundDeployer} from "tests/interfaces/internal/IFundDeployer.sol";
import {IValueInterpreter} from "tests/interfaces/internal/IValueInterpreter.sol";
import {IYearnVaultV2PriceFeed} from "tests/interfaces/internal/IYearnVaultV2PriceFeed.sol";

import {
    ETHEREUM_YEARN_VAULT_V2_REGISTRY,
    ETHEREUM_YEARN_VAULT_V2_USDT_VAULT,
    ETHEREUM_YEARN_VAULT_V2_WETH_VAULT
} from "./YearnVaultV2Contants.sol";

abstract contract YearnVaultV2PriceFeedTestBase is IntegrationTest {
    event CTokenAdded(address indexed cToken, address indexed token);

    event DerivativeAdded(address indexed derivative, address indexed underlying);

    IYearnVaultV2PriceFeed internal priceFeed;

    EnzymeVersion internal version;

    function __initialize(EnzymeVersion _version) internal {
        setUpMainnetEnvironment();
        version = _version;
        priceFeed = __deployPriceFeed();
    }

    function __renitialize(uint256 _forkBlock) private {
        setUpMainnetEnvironment(_forkBlock);
        priceFeed = __deployPriceFeed();
    }

    // DEPLOYMENT HELPERS

    function __deployPriceFeed() private returns (IYearnVaultV2PriceFeed priceFeed_) {
        address addr = deployCode(
            "YearnVaultV2PriceFeed.sol",
            abi.encode(getFundDeployerAddressForVersion(version), ETHEREUM_YEARN_VAULT_V2_REGISTRY)
        );
        return IYearnVaultV2PriceFeed(addr);
    }

    // TEST HELPERS

    function __prankFundDeployerOwner() internal {
        vm.prank(IFundDeployer(getFundDeployerAddressForVersion({_version: version})).getOwner());
    }

    // TESTS

    function test_calcUnderlyingValues18Decimals_success() public {
        __renitialize(18057000);

        __prankFundDeployerOwner();
        priceFeed.addDerivatives({
            _derivatives: toArray(ETHEREUM_YEARN_VAULT_V2_WETH_VAULT),
            _underlyings: toArray(ETHEREUM_WETH)
        });

        addDerivative({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: ETHEREUM_YEARN_VAULT_V2_WETH_VAULT,
            _skipIfRegistered: false,
            _priceFeedAddress: address(priceFeed)
        });

        assertValueInUSDForVersion({
            _version: version,
            _asset: ETHEREUM_YEARN_VAULT_V2_WETH_VAULT,
            _amount: assetUnit(IERC20(ETHEREUM_YEARN_VAULT_V2_WETH_VAULT)),
            _expected: 1701235600035248949641 // 1701.2356000352488 USD
        });
    }

    function test_calcUnderlyingValuesNon18Decimals_success() public {
        __renitialize(18056000);

        __prankFundDeployerOwner();
        priceFeed.addDerivatives({
            _derivatives: toArray(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT),
            _underlyings: toArray(ETHEREUM_USDT)
        });

        addDerivative({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT,
            _skipIfRegistered: false,
            _priceFeedAddress: address(priceFeed)
        });

        assertValueInUSDForVersion({
            _version: version,
            _asset: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT,
            _amount: assetUnit(IERC20(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT)),
            _expected: 1022772823199456796 // 1.0227728231994568 USD
        });
    }

    function test_calcUnderlyingValuesInvariant_success() public {
        __prankFundDeployerOwner();
        priceFeed.addDerivatives({
            _derivatives: toArray(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT),
            _underlyings: toArray(ETHEREUM_USDT)
        });

        addDerivative({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT,
            _skipIfRegistered: false,
            _priceFeedAddress: address(priceFeed)
        });

        uint256 value = IValueInterpreter(getValueInterpreterAddressForVersion(version)).calcCanonicalAssetValue({
            _baseAsset: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT,
            _amount: assetUnit(IERC20(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT)),
            _quoteAsset: ETHEREUM_USDT
        });

        uint256 underlyingSingleUnit = assetUnit(IERC20(ETHEREUM_USDT));

        assertGe(value, underlyingSingleUnit, "Value is less than underlying single unit");
        assertLe(
            value,
            underlyingSingleUnit + underlyingSingleUnit * 4 * BPS_ONE_PERCENT / BPS_ONE_HUNDRED_PERCENT, // allowed deviation of 4%
            "Value is more than underlying upper limit"
        );
    }

    function test_calcUnderlyingValues_failUnsupportedDerivative() public {
        vm.expectRevert("calcUnderlyingValues: Unsupported derivative");
        priceFeed.calcUnderlyingValues({_derivative: makeAddr("fake token"), _derivativeAmount: 1});
    }

    function test_isSupportedAsset_success() public {
        assertFalse(priceFeed.isSupportedAsset({_asset: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT}), "Supported token");

        __prankFundDeployerOwner();

        expectEmit(address(priceFeed));
        emit DerivativeAdded(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT, ETHEREUM_USDT);

        priceFeed.addDerivatives({
            _derivatives: toArray(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT),
            _underlyings: toArray(ETHEREUM_USDT)
        });

        assertTrue(priceFeed.isSupportedAsset({_asset: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT}), "Unsupported token");
    }

    function test_addDerivates_failInvalidYVaultForUnderlying() public {
        __prankFundDeployerOwner();
        vm.expectRevert("__validateDerivative: Invalid yVault for underlying");
        priceFeed.addDerivatives({
            _derivatives: toArray(ETHEREUM_YEARN_VAULT_V2_WETH_VAULT),
            _underlyings: toArray(ETHEREUM_USDT)
        });
    }

    function test_addDerivates_failIncongruentDecimals() public {
        __prankFundDeployerOwner();
        vm.mockCall({
            callee: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT,
            data: abi.encodeWithSignature("decimals()"),
            returnData: abi.encode(15)
        });
        vm.expectRevert("__validateDerivative: Incongruent decimals");
        priceFeed.addDerivatives({
            _derivatives: toArray(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT),
            _underlyings: toArray(ETHEREUM_USDT)
        });
    }
}

contract YearnVaultV2PriceFeedTestEthereum is YearnVaultV2PriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.Current);
    }
}

contract YearnVaultV2PriceFeedTestEthereumV4 is YearnVaultV2PriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.V4);
    }
}
