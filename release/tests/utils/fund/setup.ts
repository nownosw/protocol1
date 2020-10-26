import {
  AddressLike,
  randomAddress,
  resolveAddress,
} from '@crestproject/crestproject';
import { assertEvent } from '@melonproject/utils';
import { BigNumber, BigNumberish, BytesLike, Signer, utils } from 'ethers';
import {
  ComptrollerLib,
  ComptrollerProxy,
  FundDeployer,
  VaultLib,
} from '../../../utils/contracts';
import {
  buyShares,
  BuySharesParams,
  DenominationAssetInterface,
} from './shares';

export type InitialInvestmentParams = Omit<
  BuySharesParams,
  'comptrollerProxy' | 'denominationAsset'
>;

export interface CreateMigratedFundConfigParams {
  signer: Signer;
  fundDeployer: FundDeployer;
  denominationAsset: DenominationAssetInterface;
  sharesActionTimelock?: BigNumberish;
  feeManagerConfigData?: BytesLike;
  policyManagerConfigData?: BytesLike;
}

export interface CreateNewFundParams {
  signer: Signer;
  fundDeployer: FundDeployer;
  denominationAsset: DenominationAssetInterface;
  sharesActionTimelock?: BigNumberish;
  fundOwner?: AddressLike;
  fundName?: string;
  feeManagerConfig?: BytesLike;
  policyManagerConfig?: BytesLike;
  investment?: InitialInvestmentParams;
}

export async function createComptrollerProxy({
  signer,
  comptrollerLib,
  denominationAsset,
  sharesActionTimelock = 0,
  feeManagerConfigData = '0x',
  policyManagerConfigData = '0x',
}: {
  signer: Signer;
  comptrollerLib: ComptrollerLib;
  denominationAsset: AddressLike;
  sharesActionTimelock?: BigNumberish;
  feeManagerConfigData?: BytesLike;
  policyManagerConfigData?: BytesLike;
}) {
  const constructData = comptrollerLib.abi.encodeFunctionData(
    comptrollerLib.init.fragment,
    [
      denominationAsset,
      sharesActionTimelock,
      feeManagerConfigData,
      policyManagerConfigData,
    ],
  );
  const comptrollerProxyContract = await ComptrollerProxy.deploy(
    signer,
    constructData,
    comptrollerLib,
  );
  const deployComptrollerProxyReceipt = comptrollerProxyContract.deployment!;

  return {
    comptrollerProxy: new ComptrollerLib(
      comptrollerProxyContract.address,
      signer,
    ),
    deployComptrollerProxyReceipt,
  };
}

export async function createMigratedFundConfig({
  signer,
  fundDeployer,
  denominationAsset,
  sharesActionTimelock = 0,
  feeManagerConfigData = '0x',
  policyManagerConfigData = '0x',
}: CreateMigratedFundConfigParams) {
  const newFundConfigTx = fundDeployer
    .connect(signer)
    .createMigratedFundConfig(
      denominationAsset,
      sharesActionTimelock,
      feeManagerConfigData,
      policyManagerConfigData,
    );
  await expect(newFundConfigTx).resolves.toBeReceipt();

  const signerAddress = await resolveAddress(signer);
  const denominationAssetAddress = await resolveAddress(denominationAsset);
  const comptrollerDeployedArgs = await assertEvent(
    newFundConfigTx,
    'ComptrollerProxyDeployed',
    {
      creator: signerAddress,
      comptrollerProxy: expect.any(String) as string,
      denominationAsset: denominationAssetAddress,
      sharesActionTimelock: BigNumber.from(sharesActionTimelock),
      feeManagerConfigData: utils.hexlify(feeManagerConfigData),
      policyManagerConfigData: utils.hexlify(policyManagerConfigData),
      forMigration: true,
    },
  );

  return {
    comptrollerProxy: new ComptrollerLib(
      comptrollerDeployedArgs.comptrollerProxy,
      signer,
    ),
    newFundConfigTx,
  };
}

// TODO: should we pass in the fundOwner as a signer also so we can connect comptroller proxy and vault proxy to that acct instead?
export async function createNewFund({
  signer,
  fundDeployer,
  denominationAsset,
  sharesActionTimelock = 0,
  fundOwner = randomAddress(),
  fundName = 'My Fund',
  feeManagerConfig = '0x',
  policyManagerConfig = '0x',
  investment,
}: CreateNewFundParams) {
  const newFundTx = fundDeployer
    .connect(signer)
    .createNewFund(
      fundOwner,
      fundName,
      denominationAsset,
      sharesActionTimelock,
      feeManagerConfig,
      policyManagerConfig,
    );
  await expect(newFundTx).resolves.toBeReceipt();

  const comptrollerDeployedArgs = await assertEvent(
    newFundTx,
    'ComptrollerProxyDeployed',
    {
      creator: await resolveAddress(signer),
      comptrollerProxy: expect.any(String) as string,
      denominationAsset: await resolveAddress(denominationAsset),
      sharesActionTimelock: BigNumber.from(sharesActionTimelock),
      feeManagerConfigData: utils.hexlify(feeManagerConfig),
      policyManagerConfigData: utils.hexlify(policyManagerConfig),
      forMigration: false,
    },
  );

  const comptrollerProxy = new ComptrollerLib(
    comptrollerDeployedArgs.comptrollerProxy,
    signer,
  );

  const creator = await resolveAddress(signer);
  const fundOwnerAddress = await resolveAddress(fundOwner);
  const denominationAssetAddress = await resolveAddress(denominationAsset);

  const newFundDeployedArgs = await assertEvent(newFundTx, 'NewFundCreated', {
    creator,
    comptrollerProxy: comptrollerProxy.address,
    vaultProxy: expect.any(String) as string,
    fundOwner: fundOwnerAddress,
    fundName,
    denominationAsset: denominationAssetAddress,
    sharesActionTimelock: BigNumber.from(sharesActionTimelock),
    feeManagerConfigData: utils.hexlify(feeManagerConfig),
    policyManagerConfigData: utils.hexlify(policyManagerConfig),
  });

  const vaultProxy = new VaultLib(newFundDeployedArgs.vaultProxy, signer);

  if (investment != null) {
    await buyShares({
      comptrollerProxy,
      denominationAsset,
      ...investment,
    });
  }

  return {
    comptrollerProxy,
    newFundTx,
    vaultProxy,
  };
}
