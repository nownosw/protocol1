// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {IERC20} from "tests/interfaces/external/IERC20.sol";
import {IYearnVaultV2Vault} from "tests/interfaces/external/IYearnVaultV2Vault.sol";

import {IYearnVaultV2PriceFeed} from "tests/interfaces/internal/IYearnVaultV2PriceFeed.sol";
import {IFundDeployer} from "tests/interfaces/internal/IFundDeployer.sol";

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

    // DEPLOYMENT HELPERS

    function __deployPriceFeed() private returns (IYearnVaultV2PriceFeed priceFeed_) {
        address addr = deployCode(
            "YearnVaultV2PriceFeed.sol",
            abi.encode(getFundDeployerAddressForVersion(version), ETHEREUM_YEARN_VAULT_V2_REGISTRY)
        );
        return IYearnVaultV2PriceFeed(addr);
    }

    // TEST HELPERS

    function __test_calcUnderlyingValues_success(address _derivative, uint256 _derivativeAmount) internal {
        address[] memory underlyings = toArray(address(IYearnVaultV2Vault(_derivative).token()));

        vm.prank(IFundDeployer(getFundDeployerAddressForVersion({_version: version})).getOwner());
        priceFeed.addDerivatives({_derivatives: toArray(_derivative), _underlyings: underlyings});

        uint256 expectedUnderlyingValue =
            _derivativeAmount * IYearnVaultV2Vault(_derivative).pricePerShare() / assetUnit(IERC20(_derivative));

        (address[] memory underlyingAddresses, uint256[] memory underlyingValues) =
            priceFeed.calcUnderlyingValues({_derivative: _derivative, _derivativeAmount: _derivativeAmount});

        assertEq(underlyings, underlyingAddresses, "Mismatch between actual and expected underlying address");
        assertEq(
            toArray(expectedUnderlyingValue), underlyingValues, "Mismatch between actual and expected underlying value"
        );
    }

    // TESTS

    function test_calcUnderlyingValuesNon18DecimalsAsset_success() public {
        __test_calcUnderlyingValues_success({
            _derivative: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT,
            _derivativeAmount: 3 * assetUnit(IERC20(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT))
        });
    }

    function test_calcUnderlyingValues18DecimalsAsset_success() public {
        __test_calcUnderlyingValues_success({
            _derivative: ETHEREUM_YEARN_VAULT_V2_WETH_VAULT,
            _derivativeAmount: 12 * assetUnit(IERC20(ETHEREUM_YEARN_VAULT_V2_WETH_VAULT))
        });
    }

    function test_calcUnderlyingValues_failUnsupportedDerivative() public {
        vm.expectRevert("calcUnderlyingValues: Unsupported derivative");
        priceFeed.calcUnderlyingValues({_derivative: makeAddr("fake token"), _derivativeAmount: 1});
    }

    function test_isSupportedAsset_success() public {
        assertFalse(priceFeed.isSupportedAsset({_asset: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT}), "Supported token");

        vm.prank(IFundDeployer(getFundDeployerAddressForVersion({_version: version})).getOwner());

        expectEmit(address(priceFeed));
        emit DerivativeAdded(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT, ETHEREUM_USDT);

        priceFeed.addDerivatives({
            _derivatives: toArray(ETHEREUM_YEARN_VAULT_V2_USDT_VAULT),
            _underlyings: toArray(ETHEREUM_USDT)
        });

        assertTrue(priceFeed.isSupportedAsset({_asset: ETHEREUM_YEARN_VAULT_V2_USDT_VAULT}), "Unsupported token");
    }

    function test_addDerivates_failInvalidYVaultForUnderlying() public {
        vm.prank(IFundDeployer(getFundDeployerAddressForVersion({_version: version})).getOwner());
        vm.expectRevert("__validateDerivative: Invalid yVault for underlying");
        priceFeed.addDerivatives({
            _derivatives: toArray(ETHEREUM_YEARN_VAULT_V2_WETH_VAULT),
            _underlyings: toArray(ETHEREUM_USDT)
        });
    }

    function test_addDerivates_failIncongruentDecimals() public {
        vm.prank(IFundDeployer(getFundDeployerAddressForVersion({_version: version})).getOwner());
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
