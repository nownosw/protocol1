import type { VaultLibArgs } from '@enzymefinance/protocol';
import { FundDeployer as FundDeployerContract } from '@enzymefinance/protocol';
import type { DeployFunction } from 'hardhat-deploy/types';

import { loadConfig } from '../../../utils/config';

const fn: DeployFunction = async function (hre) {
  const {
    deployments: { deploy, get, log },
    ethers: { getSigners },
  } = hre;

  const deployer = (await getSigners())[0];
  const config = await loadConfig(hre);
  const externalPositionManager = await get('ExternalPositionManager');
  const fundDeployer = await get('FundDeployer');
  const gasRelayPaymasterFactory = await get('GasRelayPaymasterFactory');
  const protocolFeeReserveProxy = await get('ProtocolFeeReserveProxy');
  const protocolFeeTracker = await get('ProtocolFeeTracker');

  const vaultLib = await deploy('VaultLib', {
    args: [
      externalPositionManager.address,
      gasRelayPaymasterFactory.address,
      protocolFeeReserveProxy.address,
      protocolFeeTracker.address,
      config.primitives.mln,
      config.weth,
    ] as VaultLibArgs,
    from: deployer.address,
    log: true,
    skipIfAlreadyDeployed: true,
  });

  if (vaultLib.newlyDeployed) {
    const fundDeployerInstance = new FundDeployerContract(fundDeployer.address, deployer);
    log('Updating VaultLib on FundDeployer');
    await fundDeployerInstance.setVaultLib(vaultLib.address);
  }
};

fn.tags = ['Release', 'VaultLib'];
fn.dependencies = [
  'Config',
  'ExternalPositionManager',
  'GasRelayPaymasterFactory',
  'ProtocolFeeReserve',
  'ProtocolFeeTracker',
];

export default fn;
