// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";
import {IArrakisV2Helper} from "tests/interfaces/external/IArrakisV2Helper.sol";
import {IArrakisV2Resolver} from "tests/interfaces/external/IArrakisV2Resolver.sol";
import {IArrakisV2Vault} from "tests/interfaces/external/IArrakisV2Vault.sol";
import {IERC20} from "tests/interfaces/external/IERC20.sol";
import {IArrakisV2Adapter} from "tests/interfaces/internal/IArrakisV2Adapter.sol";
import {IComptrollerLib} from "tests/interfaces/internal/IComptrollerLib.sol";
import {IVaultLib} from "tests/interfaces/internal/IVaultLib.sol";
import {SpendAssetsHandleType} from "tests/utils/core/AdapterUtils.sol";
import {
    ARRAKIS_HELPER_ADDRESS,
    ARRAKIS_RESOLVER_ADDRESS,
    ETHEREUM_ARRAKIS_DAI_WETH,
    POLYGON_ARRAKIS_USDC_WETH
} from "./ArrakisV2Utils.sol";

abstract contract ArrakisV2AdapterTestBase is IntegrationTest {
    address internal vaultOwner = makeAddr("VaultOwner");

    IVaultLib internal vaultProxy;
    IComptrollerLib internal comptrollerProxy;

    IArrakisV2Adapter internal arrakisAdapter;
    IArrakisV2Helper internal arrakisHelper;
    IArrakisV2Resolver internal arrakisResolver;
    IArrakisV2Vault internal arrakisVault;
    IERC20 internal token0;
    IERC20 internal token1;

    function setUp(address _arrakisVaultAddress, address _arrakisHelperAddress, address _arrakisResolverAddress)
        internal
    {
        arrakisHelper = IArrakisV2Helper(_arrakisHelperAddress);
        arrakisResolver = IArrakisV2Resolver(_arrakisResolverAddress);
        arrakisVault = IArrakisV2Vault(_arrakisVaultAddress);

        arrakisAdapter = __deployAdapter();

        token0 = IERC20(arrakisVault.token0());
        token1 = IERC20(arrakisVault.token1());

        addPrimitivesWithTestAggregator({
            _valueInterpreter: core.release.valueInterpreter,
            _tokenAddresses: toArray(address(token0), address(token1), address(arrakisVault)),
            _skipIfRegistered: true
        });

        // Create a fund with the ArrakisV2 token0 as the denomination asset
        (comptrollerProxy, vaultProxy) = createVaultAndBuyShares({
            _fundDeployer: core.release.fundDeployer,
            _vaultOwner: vaultOwner,
            _sharesBuyer: vaultOwner,
            _denominationAsset: address(token0),
            _amountToDeposit: assetUnit(token0) * 31
        });

        // Seed the fund with some token1
        increaseTokenBalance({_token: token1, _to: address(vaultProxy), _amount: assetUnit(token1) * 23});

        // Allow adapter to mint Arrakis shares
        vm.prank(arrakisVault.owner());
        arrakisVault.setRestrictedMint(address(arrakisAdapter));
    }

    // DEPLOYMENT HELPERS

    function __deployAdapter() private returns (IArrakisV2Adapter) {
        bytes memory args = abi.encode(core.release.integrationManager);
        address addr = deployCode("ArrakisV2Adapter.sol", args);
        return IArrakisV2Adapter(addr);
    }

    // ACTION HELPERS

    function __lend(uint256[2] memory _maxUnderlyingAmounts, uint256 _sharesAmount) private {
        bytes memory integrationData = abi.encode(arrakisVault, _maxUnderlyingAmounts, _sharesAmount);
        bytes memory callArgs = abi.encode(address(arrakisAdapter), IArrakisV2Adapter.lend.selector, integrationData);

        callOnIntegration({
            _integrationManager: core.release.integrationManager,
            _comptrollerProxy: comptrollerProxy,
            _caller: vaultOwner,
            _callArgs: callArgs
        });
    }

    function __redeem(uint256 _sharesAmount, uint256[2] memory _minIncomingTokenAmounts) private {
        bytes memory integrationData = abi.encode(address(arrakisVault), _sharesAmount, _minIncomingTokenAmounts);
        bytes memory callArgs = abi.encode(address(arrakisAdapter), IArrakisV2Adapter.redeem.selector, integrationData);

        callOnIntegration({
            _integrationManager: core.release.integrationManager,
            _comptrollerProxy: comptrollerProxy,
            _caller: vaultOwner,
            _callArgs: callArgs
        });
    }

    function test_lend_success() public {
        uint256 token0BalancePre = token0.balanceOf(address(vaultProxy));
        uint256 token0MaxAmount = token0BalancePre / 5;
        uint256 token1BalancePre = token1.balanceOf(address(vaultProxy));
        uint256 token1MaxAmount = token1BalancePre / 5;

        assertNotEq(token0MaxAmount, 0, "token0 amount to deposit is 0");
        assertNotEq(token1MaxAmount, 0, "token1 amount to deposit is 0");

        (uint256 expectedToken0Amount, uint256 expectedToken1Amount, uint256 expectedSharesAmount) = arrakisResolver
            .getMintAmounts({_vaultV2: address(arrakisVault), _amount0Max: token0MaxAmount, _amount1Max: token1MaxAmount});

        vm.recordLogs();

        __lend({_maxUnderlyingAmounts: [token0MaxAmount, token1MaxAmount], _sharesAmount: expectedSharesAmount});

        // Test parseAssetsForAction encoding
        assertAdapterAssetsForAction({
            _logs: vm.getRecordedLogs(),
            _spendAssetsHandleType: SpendAssetsHandleType.Transfer,
            _spendAssets: toArray(address(token0), address(token1)),
            _maxSpendAssetAmounts: toArray(token0MaxAmount, token1MaxAmount),
            _incomingAssets: toArray(address(arrakisVault)),
            _minIncomingAssetAmounts: toArray(expectedSharesAmount)
        });

        // Assert the expected final vaultProxy balances
        assertEq(
            IERC20(address(arrakisVault)).balanceOf(address(vaultProxy)),
            expectedSharesAmount,
            "Mismatch between received and expected arrakis vault balance"
        );
        assertEq(
            token0BalancePre - token0.balanceOf(address(vaultProxy)),
            expectedToken0Amount,
            "Mismatch between sent and expected token0 balance"
        );
        assertEq(
            token1BalancePre - token1.balanceOf(address(vaultProxy)),
            expectedToken1Amount,
            "Mismatch between sent and expected token1 balance"
        );

        // Assert that no token balances remain in the adapter
        assertEq(token0.balanceOf(address(arrakisAdapter)), 0, "Adapter has token0 balance");
        assertEq(token1.balanceOf(address(arrakisAdapter)), 0, "Adapter has token1 balance");
    }

    function test_redeem_success() public {
        uint256 token0MaxAmount = token0.balanceOf(address(vaultProxy)) / 5;
        uint256 token1MaxAmount = token1.balanceOf(address(vaultProxy)) / 5;

        (,, uint256 expectedSharesAmount) = arrakisResolver.getMintAmounts({
            _vaultV2: address(arrakisVault),
            _amount0Max: token0MaxAmount,
            _amount1Max: token1MaxAmount
        });

        __lend({_maxUnderlyingAmounts: [token0MaxAmount, token1MaxAmount], _sharesAmount: expectedSharesAmount});

        uint256 token0BalancePre = token0.balanceOf(address(vaultProxy));
        uint256 token1BalancePre = token1.balanceOf(address(vaultProxy));
        uint256 sharesBalance = IERC20(address(arrakisVault)).balanceOf(address(vaultProxy));

        uint256 sharesToRedeem = sharesBalance / 3;

        uint256 arrakisVaultSupply = IERC20(address(arrakisVault)).totalSupply();
        (uint256 totalUnderlying0, uint256 totalUnderlying1) = arrakisHelper.totalUnderlying(address(arrakisVault));

        uint256 expectedToken0Amount = (totalUnderlying0 * sharesToRedeem) / arrakisVaultSupply;
        uint256 expectedToken1Amount = (totalUnderlying1 * sharesToRedeem) / arrakisVaultSupply;

        vm.recordLogs();

        uint256 minIncomingToken0Amount = expectedToken0Amount * 99 / 100;
        uint256 minIncomingToken1Amount = expectedToken1Amount * 99 / 100;

        __redeem({
            _sharesAmount: sharesToRedeem,
            _minIncomingTokenAmounts: [minIncomingToken0Amount, minIncomingToken1Amount]
        });

        // Test parseAssetsForAction encoding
        assertAdapterAssetsForAction({
            _logs: vm.getRecordedLogs(),
            _spendAssetsHandleType: SpendAssetsHandleType.Transfer,
            _spendAssets: toArray(address(arrakisVault)),
            _maxSpendAssetAmounts: toArray(sharesToRedeem),
            _incomingAssets: toArray(address(token0), address(token1)),
            _minIncomingAssetAmounts: toArray(minIncomingToken0Amount, minIncomingToken1Amount)
        });

        uint256 expectedToken0Balance = token0BalancePre + expectedToken0Amount;
        uint256 expectedToken1Balance = token1BalancePre + expectedToken1Amount;

        // Allow for a slight difference in returned amounts due to rounding and supply-based estimation calcs
        assertApproxEqAbs(
            token0.balanceOf(address(vaultProxy)),
            expectedToken0Balance,
            10 wei,
            "Mismatch between received and expected arrakis token0 balance"
        );

        assertApproxEqAbs(
            token1.balanceOf(address(vaultProxy)),
            expectedToken1Balance,
            10 wei,
            "Mismatch between received and expected arrakis token1 balance"
        );
    }
}

contract DaiWethEthereumTest is ArrakisV2AdapterTestBase {
    function setUp() public override {
        setUpMainnetEnvironment();
        setUp({
            _arrakisVaultAddress: ETHEREUM_ARRAKIS_DAI_WETH,
            _arrakisHelperAddress: ARRAKIS_HELPER_ADDRESS,
            _arrakisResolverAddress: ARRAKIS_RESOLVER_ADDRESS
        });
    }
}

contract WmaticWethPolygonTest is ArrakisV2AdapterTestBase {
    function setUp() public override {
        setUpPolygonEnvironment();
        setUp({
            _arrakisVaultAddress: POLYGON_ARRAKIS_USDC_WETH,
            _arrakisHelperAddress: ARRAKIS_HELPER_ADDRESS,
            _arrakisResolverAddress: ARRAKIS_RESOLVER_ADDRESS
        });
    }
}
