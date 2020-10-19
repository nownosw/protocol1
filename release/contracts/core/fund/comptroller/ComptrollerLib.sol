// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../../../extensions/IExtension.sol";
import "../../../extensions/fee-manager/IFeeManager.sol";
import "../../../extensions/policy-manager/IPolicyManager.sol";
import "../../../infrastructure/engine/AmguConsumer.sol";
import "../../../infrastructure/price-feeds/primitives/IPrimitivePriceFeed.sol";
import "../../../infrastructure/value-interpreter/IValueInterpreter.sol";
import "../../../interfaces/IERC20Extended.sol";
import "../../fund-deployer/IFundDeployer.sol";
import "../vault/IVault.sol";
import "./IComptroller.sol";

/// @title ComptrollerLib Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice The core logic library shared by all funds
/// @dev All state-changing functions should be marked as onlyDelegateCall,
/// unless called directly by the FundDeployer
contract ComptrollerLib is IComptroller, AmguConsumer {
    using SafeMath for uint256;
    using SafeERC20 for IERC20Extended;

    event MigratedSharesDuePaid(address payee, uint256 sharesDue);

    event OverridePauseSet(bool indexed overridePause);

    event SharesBought(
        address indexed caller,
        address indexed buyer,
        uint256 investmentAmount,
        uint256 sharesBought,
        uint256 sharesReceived
    );

    event SharesRedeemed(
        address indexed redeemer,
        uint256 sharesQuantity,
        address[] receivedAssets,
        uint256[] receivedAssetQuantities
    );

    event VaultProxySet(address vaultProxy);

    // Constants - shared by all proxies
    uint256 private constant SHARES_UNIT = 10**18;
    address private immutable FUND_DEPLOYER;
    address private immutable FEE_MANAGER;
    address private immutable INTEGRATION_MANAGER;
    address private immutable POLICY_MANAGER;
    address private immutable PRIMITIVE_PRICE_FEED;
    address private immutable VALUE_INTERPRETER;

    // Pseudo-constants (can only be set once)
    address private denominationAsset;
    // True only for the one non-proxy
    bool private isLib;
    address private vaultProxy;

    // Storage
    // Allows a fund owner to override a release-level pause
    bool private overridePause;
    // A reverse-mutex, granting atomic permission for particular contracts to make vault calls
    bool private permissionedVaultCallAllowed;
    // A mutex
    bool private reentranceLocked;

    ///////////////
    // MODIFIERS //
    ///////////////

    modifier allowsPermissionedVaultCall {
        __assertPermissionedVaultCallNotAllowed();
        permissionedVaultCallAllowed = true;
        _;
        permissionedVaultCallAllowed = false;
    }

    /// @dev Especially because the current asset universe is limited to non-reentrant ERC20 tokens,
    /// this reentrancy guard is not strictly necessary, but implemented out of an abundance of
    /// caution in the case we decide that we do want to allow such assets.
    modifier locksReentrance() {
        __assertNotReentranceLocked();
        reentranceLocked = true;
        _;
        reentranceLocked = false;
    }

    modifier onlyActive() {
        __assertIsActive();
        _;
    }

    modifier onlyDelegateCall() {
        __assertIsDelegateCall();
        _;
    }

    modifier onlyFundDeployer() {
        __assertIsFundDeployer(msg.sender);
        _;
    }

    modifier onlyNotPaused() {
        __assertNotPaused();
        _;
    }

    modifier onlyOwner() {
        __assertIsOwner(msg.sender);
        _;
    }

    /// @dev We are overly cautious about protecting VaultProxy state-altering calls
    modifier onlyPermissionedRequest(IVault.VaultAction _action) {
        __assertNotPaused();
        __assertIsActive();
        __assertValidCallFromExtension(msg.sender, _action);
        _;
    }

    // MODIFIER HELPERS
    // Modifiers are inefficient in terms of reducing contract size,
    // so we use helper functions to prevent repetitive inlining of expensive string values.

    function __assertIsActive() private view {
        require(isActive(), "This function can only be called on an active fund");
    }

    function __assertIsFundDeployer(address _who) private view {
        require(_who == FUND_DEPLOYER, "Only the FundDeployer can call this function");
    }

    function __assertIsDelegateCall() private view {
        require(!isLib, "Only a delegate call can access this function");
    }

    function __assertIsOwner(address _who) private view {
        require(
            _who == IVault(vaultProxy).getOwner(),
            "Only the fund owner can call this function"
        );
    }

    function __assertNotPaused() private view {
        require(!__fundIsPaused(), "Fund is paused");
    }

    function __assertNotReentranceLocked() private view {
        require(!reentranceLocked, "Re-entrance detected");
    }

    function __assertPermissionedVaultCallNotAllowed() private view {
        require(!permissionedVaultCallAllowed, "Permissioned vault call re-entrance detected");
    }

    function __assertValidCallFromExtension(address _extension, IVault.VaultAction _action)
        private
        view
    {
        require(permissionedVaultCallAllowed, "Call does not originate from contract");

        if (_extension == INTEGRATION_MANAGER) {
            require(
                _action == IVault.VaultAction.ApproveAssetSpender ||
                    _action == IVault.VaultAction.WithdrawAssetTo ||
                    _action == IVault.VaultAction.AddTrackedAsset ||
                    _action == IVault.VaultAction.RemoveTrackedAsset,
                "Not a valid action for IntegrationManager"
            );
        } else if (_extension == FEE_MANAGER) {
            require(
                _action == IVault.VaultAction.BurnShares ||
                    _action == IVault.VaultAction.MintShares,
                "Not a valid action for FeeManager"
            );
        } else {
            revert("Not a valid call from extension");
        }
    }

    constructor(
        address _fundDeployer,
        address _valueInterpreter,
        address _primitivePriceFeed,
        address _feeManager,
        address _integrationManager,
        address _policyManager,
        address _engine
    ) public AmguConsumer(_engine) {
        FEE_MANAGER = _feeManager;
        FUND_DEPLOYER = _fundDeployer;
        INTEGRATION_MANAGER = _integrationManager;
        POLICY_MANAGER = _policyManager;
        PRIMITIVE_PRICE_FEED = _primitivePriceFeed;
        VALUE_INTERPRETER = _valueInterpreter;
        isLib = true;
    }

    /////////////
    // GENERAL //
    /////////////

    /// @notice Calls an arbitrary function on an extension
    /// @param _extension The extension contract to call (e.g., FeeManager)
    /// @param _selector The selector to call
    /// @param _callArgs The encoded data for the call
    /// @dev Used to route arbitrary calls, so that msg.sender is the ComptrollerProxy (for access control).
    /// Uses a reverse-mutex of sorts that only allows permissioned calls to the vault during this stack.
    /// Does not use onlyDelegateCall, as onlyActive will only be valid in delegate calls.
    function callOnExtension(
        address _extension,
        bytes4 _selector,
        bytes calldata _callArgs
    ) external onlyNotPaused onlyActive locksReentrance allowsPermissionedVaultCall {
        require(
            _extension == FEE_MANAGER ||
                _extension == POLICY_MANAGER ||
                _extension == INTEGRATION_MANAGER,
            "callOnExtension: _extension is not valid"
        );

        (bool success, bytes memory returnData) = _extension.call(
            abi.encodeWithSelector(_selector, msg.sender, _callArgs)
        );
        require(success, string(returnData));
    }

    function setOverridePause(bool _overridePause) external onlyDelegateCall onlyOwner {
        require(
            _overridePause != overridePause,
            "setOverridePause: _overridePause is already the set value"
        );

        overridePause = _overridePause;

        emit OverridePauseSet(_overridePause);
    }

    /// @notice Makes an arbitrary call from the VaultProxy contract
    /// @param _contract The contract to call
    /// @param _selector The selector to call
    /// @param _callData The call data for the call
    /// @dev Does not use onlyDelegateCall, as onlyActive will only be valid in delegate calls.
    function vaultCallOnContract(
        address _contract,
        bytes4 _selector,
        bytes calldata _callData
    ) external onlyNotPaused onlyActive onlyOwner {
        require(
            IFundDeployer(FUND_DEPLOYER).isRegisteredVaultCall(_contract, _selector),
            "vaultCallOnContract: not a registered call"
        );

        IVault(vaultProxy).callOnContract(_contract, abi.encodeWithSelector(_selector, _callData));
    }

    /// @notice Checks whether the fund is active
    /// @return isActive_ True if the fund is active
    /// @dev Since vaultProxy is set during activate(),
    /// we can check that var rather than storing additional state
    function isActive() public view returns (bool isActive_) {
        return vaultProxy != address(0);
    }

    /// @dev Helper to check whether the release is paused and there is no local override
    function __fundIsPaused() private view returns (bool) {
        return
            !overridePause &&
            IFundDeployer(FUND_DEPLOYER).getReleaseStatus() == IFundDeployer.ReleaseStatus.Paused;
    }

    ///////////////
    // LIFECYCLE //
    ///////////////

    // Ordered function calls for stages in a fund lifecycle:
    // 1. init() - called on deployment of ComptrollerProxy
    // 2. activate() - called upon linking a VaultProxy to activate the fund
    // 3a. shutdown() - called by a fund owner to end the fund lifecycle
    // 3b. destruct() - called by the fund deployer

    /// @dev Pseudo-constructor per proxy.
    /// No need to assert access because this is called atomically on deployment,
    /// and once it's called, it cannot be called again.
    function init(
        address _denominationAsset,
        bytes calldata _feeManagerConfigData,
        bytes calldata _policyManagerConfigData
    ) external override onlyDelegateCall {
        require(denominationAsset == address(0), "init: Already initialized");

        // Configure core

        require(
            IPrimitivePriceFeed(PRIMITIVE_PRICE_FEED).isSupportedAsset(_denominationAsset),
            "init: Denomination asset must be a supported primitive"
        );
        denominationAsset = _denominationAsset;

        // Configure extensions
        if (_feeManagerConfigData.length > 0) {
            IExtension(FEE_MANAGER).setConfigForFund(_feeManagerConfigData);
        }
        if (_policyManagerConfigData.length > 0) {
            IExtension(POLICY_MANAGER).setConfigForFund(_policyManagerConfigData);
        }
    }

    /// @notice Activates the fund after running pre-activation logic
    /// @param _vaultProxy The VaultProxy to attach to the fund
    /// @param _isMigration True if a migrated fund is being activated
    /// @dev No need to assert anything beyond FundDeployer access.
    function activate(address _vaultProxy, bool _isMigration) external override onlyFundDeployer {
        vaultProxy = _vaultProxy;

        emit VaultProxySet(_vaultProxy);

        if (_isMigration) {
            // Distribute any shares in the VaultProxy to the fund owner.
            // This is a mechanism to ensure that even in the edge case of a fund being unable
            // to payout fee shares owed during migration, these shares are not lost.
            uint256 sharesDue = IERC20(_vaultProxy).balanceOf(_vaultProxy);
            if (sharesDue > 0) {
                address vaultOwner = IVault(_vaultProxy).getOwner();
                IVault(_vaultProxy).burnShares(_vaultProxy, sharesDue);
                IVault(_vaultProxy).mintShares(vaultOwner, sharesDue);

                emit MigratedSharesDuePaid(vaultOwner, sharesDue);
            }

            // Policies must assert that they are congruent with migrated vault state
            // There are currently no policies that alter state on activation, so we
            // only need this call for migrated fund vault validation.
            IExtension(POLICY_MANAGER).activateForFund();
        }

        // Activate remaining extensions
        IExtension(FEE_MANAGER).activateForFund();
        IExtension(INTEGRATION_MANAGER).activateForFund();
    }

    /// @notice Remove the config for a fund
    /// @dev No need to assert anything beyond FundDeployer access.
    /// Calling onlyNotPaused here rather than in the FundDeployer allows
    /// the owner to potentially override the pause and rescue unpaid fees.
    function destruct()
        external
        override
        onlyFundDeployer
        onlyNotPaused
        allowsPermissionedVaultCall
    {
        // Deactivate the extensions
        IExtension(FEE_MANAGER).deactivateForFund();
        IExtension(INTEGRATION_MANAGER).deactivateForFund();
        // TODO: destroy unneeded PolicyManager storage?

        // Delete storage of ComptrollerProxy
        // There should never be ETH in this contract, but if there is,
        // we can send to the VaultProxy.
        selfdestruct(payable(vaultProxy));
    }

    //////////////////////////////
    // PERMISSIONED VAULT CALLS //
    //////////////////////////////

    /// @notice Adds a tracked asset to the fund
    /// @param _asset The asset to add
    function addTrackedAsset(address _asset)
        external
        override
        onlyPermissionedRequest(IVault.VaultAction.AddTrackedAsset)
    {
        IVault(vaultProxy).addTrackedAsset(_asset);
    }

    /// @notice Grants an allowance to a spender to use a fund's asset
    /// @param _asset The asset for which to grant an allowance
    /// @param _target The spender of the allowance
    /// @param _amount The amount of the allowance
    function approveAssetSpender(
        address _asset,
        address _target,
        uint256 _amount
    ) external override onlyPermissionedRequest(IVault.VaultAction.ApproveAssetSpender) {
        IVault(vaultProxy).approveAssetSpender(_asset, _target, _amount);
    }

    /// @notice Burns fund shares for a particular account
    /// @param _target The account for which to burn shares
    /// @param _amount The amount of shares to burn
    function burnShares(address _target, uint256 _amount)
        external
        override
        onlyPermissionedRequest(IVault.VaultAction.BurnShares)
    {
        IVault(vaultProxy).burnShares(_target, _amount);
    }

    /// @notice Mints fund shares to a particular account
    /// @param _target The account to which to mint shares
    /// @param _amount The amount of shares to mint
    function mintShares(address _target, uint256 _amount)
        external
        override
        onlyPermissionedRequest(IVault.VaultAction.MintShares)
    {
        IVault(vaultProxy).mintShares(_target, _amount);
    }

    /// @notice Removes a tracked asset from the fund
    /// @param _asset The asset to remove
    function removeTrackedAsset(address _asset)
        external
        override
        onlyPermissionedRequest(IVault.VaultAction.RemoveTrackedAsset)
    {
        IVault(vaultProxy).removeTrackedAsset(_asset);
    }

    ////////////////
    // ACCOUNTING //
    ////////////////

    /// @notice Calculates the gross asset value (GAV) of the fund
    /// @param _useLiveRates True if should use live rates instead of canonical rates
    /// @return gav_ The fund GAV
    /// @dev _useLiveRates is `false` within the core protocol, but plugins will often want to use
    /// live rates, for example a MaxConcentration policy
    /// @dev Does not alter local state,
    /// but not a view because calls to price feeds can potentially update 3rd party state
    function calcGav(bool _useLiveRates) public onlyDelegateCall returns (uint256 gav_) {
        IVault vaultProxyContract = IVault(vaultProxy);
        address[] memory assets = vaultProxyContract.getTrackedAssets();
        uint256[] memory balances = new uint256[](assets.length);
        for (uint256 i; i < assets.length; i++) {
            balances[i] = __getVaultAssetBalance(address(vaultProxyContract), assets[i]);
        }

        bool isValid;
        if (_useLiveRates) {
            (gav_, isValid) = IValueInterpreter(VALUE_INTERPRETER).calcLiveAssetsTotalValue(
                assets,
                balances,
                denominationAsset
            );
        } else {
            (gav_, isValid) = IValueInterpreter(VALUE_INTERPRETER).calcCanonicalAssetsTotalValue(
                assets,
                balances,
                denominationAsset
            );
        }

        // TODO: return validity instead of reverting?
        require(isValid, "calcGav: gav is invalid");

        return gav_;
    }

    /// @notice Calculates the gross value of 1 unit of shares in the fund's denomination asset
    /// @return grossShareValue_ The amount of the denomination asset per share
    /// @dev Does not account for any fees outstanding
    function calcGrossShareValue() public onlyDelegateCall returns (uint256 grossShareValue_) {
        return
            __calcGrossShareValue(
                calcGav(false),
                IERC20Extended(vaultProxy).totalSupply(),
                10**uint256(IERC20Extended(denominationAsset).decimals())
            );
    }

    /// @notice Calculates the net value of 1 unit of shares in the fund's denomination asset
    /// @return netShareValue_ The amount of the denomination asset per share
    /// @dev Accounts for fees outstanding. This is a convenience function for external consumption
    /// that can be used to determine the cost of purchasing shares at any given point in time.
    function calcNetShareValue()
        external
        onlyDelegateCall
        allowsPermissionedVaultCall
        returns (uint256 netShareValue_)
    {
        IFeeManager(FEE_MANAGER).settleFees(IFeeManager.FeeHook.Continuous, "");

        return calcGrossShareValue();
    }

    /// @dev Helper for calculating the gross share value
    function __calcGrossShareValue(
        uint256 _gav,
        uint256 _sharesSupply,
        uint256 _denominationAssetUnit
    ) private pure returns (uint256 grossShareValue_) {
        if (_sharesSupply == 0) {
            return _denominationAssetUnit;
        }

        return _gav.mul(SHARES_UNIT).div(_sharesSupply);
    }

    /// @dev Helper to get the balance of an asset in a fund's VaultProxy
    function __getVaultAssetBalance(address _vaultProxy, address _asset)
        private
        view
        returns (uint256 balance_)
    {
        return IERC20Extended(_asset).balanceOf(_vaultProxy);
    }

    ///////////////////
    // PARTICIPATION //
    ///////////////////

    /// @notice Buy shares on behalf of a specified user
    /// @param _buyer The account for which to buy shares
    /// @param _investmentAmount The amount of the fund's denomination asset with which to buy shares
    /// @param _minSharesQuantity The minimum quantity of shares to buy with the specified _investmentAmount
    /// @return sharesReceived_ The actual amount of shares received by the _buyer
    /// @dev Does not use onlyDelegateCall, as onlyActive will only be valid in delegate calls.
    function buyShares(
        address _buyer,
        uint256 _investmentAmount,
        uint256 _minSharesQuantity
    )
        external
        override
        payable
        onlyActive
        onlyNotPaused
        locksReentrance
        allowsPermissionedVaultCall
        amguPayable
        returns (uint256 sharesReceived_)
    {
        uint256 preBuySharesGav = calcGav(false);

        __preBuySharesHook(_buyer, _investmentAmount, _minSharesQuantity, preBuySharesGav);

        IVault vaultProxyContract = IVault(vaultProxy);
        IERC20Extended sharesContract = IERC20Extended(address(vaultProxyContract));
        IERC20Extended denominationAssetContract = IERC20Extended(denominationAsset);

        // Calculate the amount of shares to buy with the investment amount
        uint256 denominationAssetUnit = 10**uint256(denominationAssetContract.decimals());
        uint256 sharesBought = _investmentAmount.mul(denominationAssetUnit).div(
            __calcGrossShareValue(
                preBuySharesGav,
                sharesContract.totalSupply(),
                denominationAssetUnit
            )
        );

        // Mint shares to the buyer
        uint256 prevBuyerShares = sharesContract.balanceOf(_buyer);
        vaultProxyContract.mintShares(_buyer, sharesBought);

        // Post-buy actions
        // TODO: could add additional params like gav and totalSupply here too
        __postBuySharesHook(_buyer, _investmentAmount, sharesBought);

        sharesReceived_ = sharesContract.balanceOf(_buyer).sub(prevBuyerShares);
        require(
            sharesReceived_ >= _minSharesQuantity,
            "buyShares: minimum shares quantity not met"
        );

        // Transfer investment asset
        denominationAssetContract.safeTransferFrom(
            msg.sender,
            address(vaultProxyContract),
            _investmentAmount
        );
        vaultProxyContract.addTrackedAsset(address(denominationAssetContract));

        emit SharesBought(msg.sender, _buyer, _investmentAmount, sharesBought, sharesReceived_);

        return sharesReceived_;
    }

    /// @notice Redeem all of the sender's shares for a proportionate slice of the fund's assets
    function redeemShares() external onlyDelegateCall {
        __redeemShares(IERC20Extended(vaultProxy).balanceOf(msg.sender), false);
    }

    /// @notice Redeem all of the sender's shares for a proportionate slice of the fund's assets,
    /// bypassing any failures.
    /// @dev The user will lose their claim to any assets for
    /// which the transfer function fails. Only use in the case of an emergency.
    function redeemSharesEmergency() external onlyDelegateCall {
        __redeemShares(IERC20Extended(vaultProxy).balanceOf(msg.sender), true);
    }

    /// @notice Redeem a specified quantity of the sender's shares
    /// for a proportionate slice of the fund's assets
    /// @param _sharesQuantity Number of shares
    function redeemSharesQuantity(uint256 _sharesQuantity) external onlyDelegateCall {
        __redeemShares(_sharesQuantity, false);
    }

    /// @dev Helper for system actions immediately prior to issuing shares
    function __preBuySharesHook(
        address _buyer,
        uint256 _investmentAmount,
        uint256 _minSharesQuantity,
        uint256 _gav
    ) private {
        bytes memory callData = abi.encode(_buyer, _investmentAmount, _minSharesQuantity, _gav);

        IFeeManager(FEE_MANAGER).settleFees(IFeeManager.FeeHook.PreBuyShares, callData);

        IPolicyManager(POLICY_MANAGER).validatePolicies(
            address(this),
            IPolicyManager.PolicyHook.BuyShares,
            IPolicyManager.PolicyHookExecutionTime.Pre,
            callData
        );
    }

    /// @dev Helper for system actions immediately prior to redeeming shares.
    /// Policy validation is not currently allowed on redemption, to ensure continuous redeemability.
    function __preRedeemSharesHook(address _redeemer, uint256 _sharesQuantity)
        private
        allowsPermissionedVaultCall
    {
        try
            IFeeManager(FEE_MANAGER).settleFees(
                IFeeManager.FeeHook.PreRedeemShares,
                abi.encode(_redeemer, _sharesQuantity)
            )
         {} catch {}
    }

    /// @dev Helper for system actions immediately after issuing shares
    function __postBuySharesHook(
        address _buyer,
        uint256 _investmentAmount,
        uint256 _sharesBought
    ) private {
        bytes memory callData = abi.encode(_buyer, _investmentAmount, _sharesBought);

        IFeeManager(FEE_MANAGER).settleFees(IFeeManager.FeeHook.PostBuyShares, callData);

        IPolicyManager(POLICY_MANAGER).validatePolicies(
            address(this),
            IPolicyManager.PolicyHook.BuyShares,
            IPolicyManager.PolicyHookExecutionTime.Post,
            callData
        );
    }

    /// @notice Redeem a specified quantity of the sender's shares
    /// for a proportionate slice of the fund's assets
    /// @dev If _bypassFailure is set to true, the user will lose their claim to any assets for
    /// which the transfer function fails. This should always be false unless explicitly intended
    /// @param _sharesQuantity The amount of shares to redeem
    /// @param _bypassFailure True if token transfer failures should be ignored and forfeited
    function __redeemShares(uint256 _sharesQuantity, bool _bypassFailure) private locksReentrance {
        require(_sharesQuantity > 0, "__redeemShares: _sharesQuantity must be > 0");

        address redeemer = msg.sender;

        // When a fund is paused, settling fees will be skipped
        if (!__fundIsPaused()) {
            // Note that if "direct" fees are charged here (i.e., not inflationary),
            // then those fee shares will be burned from the user's balance rather
            // than reallocated from the sharesQuantity being redeemed.
            __preRedeemSharesHook(redeemer, _sharesQuantity);
        }

        // Interfaces currently only contain their own functions that are used elsewhere
        // within the core protocol. If we change this paradigm, we can combine these vars.
        IVault vaultProxyContract = IVault(vaultProxy);
        IERC20Extended sharesContract = IERC20Extended(address(vaultProxyContract));

        // Check the shares quantity against the user's balance after settling fees.
        require(
            _sharesQuantity <= sharesContract.balanceOf(redeemer),
            "__redeemShares: _sharesQuantity exceeds sender balance"
        );

        address[] memory payoutAssets = vaultProxyContract.getTrackedAssets();
        require(payoutAssets.length > 0, "__redeemShares: fund has no tracked assets");

        // Destroy the shares.
        // Must get the shares supply before doing so.
        uint256 sharesSupply = sharesContract.totalSupply();
        vaultProxyContract.burnShares(redeemer, _sharesQuantity);

        // Calculate and transfer payout assets to redeemer
        uint256[] memory payoutQuantities = new uint256[](payoutAssets.length);
        for (uint256 i; i < payoutAssets.length; i++) {
            // Redeemer's ownership percentage of asset holdings
            payoutQuantities[i] = __getVaultAssetBalance(
                address(vaultProxyContract),
                payoutAssets[i]
            )
                .mul(_sharesQuantity)
                .div(sharesSupply);

            // Transfer payout asset to redeemer
            try
                vaultProxyContract.withdrawAssetTo(payoutAssets[i], redeemer, payoutQuantities[i])
             {} catch {
                if (!_bypassFailure) {
                    revert("__redeemShares: Token transfer failed");
                }
            }
        }

        emit SharesRedeemed(redeemer, _sharesQuantity, payoutAssets, payoutQuantities);
    }

    ///////////////////
    // STATE GETTERS //
    ///////////////////

    /// @notice Gets the `denominationAsset` variable
    /// @return denominationAsset_ The `denominationAsset` variable value
    function getDenominationAsset() external view returns (address denominationAsset_) {
        return denominationAsset;
    }

    /// @notice Gets the `overridePause` variable
    /// @return overridePause_ The `overridePause` variable value
    function getOverridePause() external view returns (bool overridePause_) {
        return overridePause;
    }

    /// @notice Gets the routes for the various contracts used by all funds
    /// @return feeManager_ The `FEE_MANAGER` variable value
    /// @return fundDeployer_ The `FUND_DEPLOYER` variable value
    /// @return integrationManager_ The `INTEGRATION_MANAGER` variable value
    /// @return policyManager_ The `POLICY_MANAGER` variable value
    /// @return primitivePriceFeed_ The `PRIMITIVE_PRICE_FEED` variable value
    /// @return valueInterpreter_ The `VALUE_INTERPRETER` variable value
    function getRoutes()
        external
        override
        view
        returns (
            address feeManager_,
            address fundDeployer_,
            address integrationManager_,
            address policyManager_,
            address primitivePriceFeed_,
            address valueInterpreter_
        )
    {
        return (
            FEE_MANAGER,
            FUND_DEPLOYER,
            INTEGRATION_MANAGER,
            POLICY_MANAGER,
            PRIMITIVE_PRICE_FEED,
            VALUE_INTERPRETER
        );
    }

    /// @notice Gets the `vaultProxy` variable
    /// @return vaultProxy_ The `vaultProxy` variable value
    function getVaultProxy() external override view returns (address vaultProxy_) {
        return vaultProxy;
    }
}
