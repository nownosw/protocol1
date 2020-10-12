import {
  EthereumTestnetProvider,
  randomAddress,
  resolveAddress,
} from '@crestproject/crestproject';
import { assertEvent } from '@melonproject/utils';
import { BigNumber, utils } from 'ethers';
import { defaultTestDeployment } from '../../../';
import { Engine, ValueInterpreter } from '../../../utils/contracts';
import { seedAndThawEngine, warpEngine } from '../../utils';

async function snapshot(provider: EthereumTestnetProvider) {
  const { accounts, deployment, config } = await defaultTestDeployment(
    provider,
  );

  return {
    accounts,
    deployment,
    config,
  };
}

async function snapshotWithMocks(provider: EthereumTestnetProvider) {
  const { accounts, deployment, config } = await provider.snapshot(snapshot);

  // Create a mock value interpreter that returns (0, false) by default
  const mockValueInterpreter = await ValueInterpreter.mock(config.deployer);
  await mockValueInterpreter.calcCanonicalAssetValue.returns(0, false);

  const mockEngineWithValueInterpreter = await Engine.deploy(
    config.deployer,
    config.dispatcher,
    randomAddress(),
    randomAddress(),
    randomAddress(),
    randomAddress(),
    mockValueInterpreter,
    1,
  );

  return {
    accounts,
    deployment,
    config,
    mocks: { mockEngineWithValueInterpreter, mockValueInterpreter },
  };
}

describe('constructor', () => {
  it('sets lastThaw to block.timestamp', async () => {
    const {
      config: { deployer },
    } = await provider.snapshot(snapshot);

    // Create a new engine to ensure it is created on the last block
    const engine = await Engine.deploy(
      deployer,
      randomAddress(),
      randomAddress(),
      randomAddress(),
      randomAddress(),
      randomAddress(),
      randomAddress(),
      1,
    );

    const block = await provider.getBlock('latest');
    const lastThawCall = engine.getLastThaw();
    await expect(lastThawCall).resolves.toEqBigNumber(block.timestamp);
  });

  it('sets state vars', async () => {
    const {
      deployment: {
        engine,
        valueInterpreter,
        chainlinkPriceFeed,
        tokens: { mln, weth },
      },
      config: {
        mgm,
        deployer,
        engine: { thawDelay },
      },
    } = await provider.snapshot(snapshot);

    const getMGM = engine.getMGM();
    await expect(getMGM).resolves.toBe(mgm);

    // The deployer should initially be the dispatcher owner.
    const dispatcherOwner = engine.getOwner();
    await expect(dispatcherOwner).resolves.toBe(await resolveAddress(deployer));

    const getPrimitivePriceFeed = engine.getPrimitivePriceFeed();
    await expect(getPrimitivePriceFeed).resolves.toBe(
      chainlinkPriceFeed.address,
    );

    const getValueInterpreter = engine.getValueInterpreter();
    await expect(getValueInterpreter).resolves.toBe(valueInterpreter.address);

    const getMLNToken = engine.getMLNToken();
    await expect(getMLNToken).resolves.toBe(mln.address);

    const getWETHToken = engine.getWETHToken();
    await expect(getWETHToken).resolves.toBe(weth.address);

    const getThawDelayCall = engine.getThawDelay();
    await expect(getThawDelayCall).resolves.toEqBigNumber(thawDelay);
  });
});

describe('setAmguPrice', () => {
  it('can only be called by MGM', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    const setAmguPriceTx = engine.setAmguPrice(1);
    await expect(setAmguPriceTx).rejects.toBeRevertedWith(
      'Only MGM can call this',
    );
  });

  it('sets amguPrice', async () => {
    const {
      config: { mgm },
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    const preAmguPriceCall = await engine.getAmguPrice();
    const priceToBeSet = 1;

    const setAmguPriceTx = engine
      .connect(provider.getSigner(mgm))
      .setAmguPrice(priceToBeSet);

    const postAmguGetPriceCall = engine.getAmguPrice();
    await expect(postAmguGetPriceCall).resolves.toEqBigNumber(priceToBeSet);

    await assertEvent(setAmguPriceTx, 'AmguPriceSet', {
      prevAmguPrice: preAmguPriceCall,
      nextAmguPrice: postAmguGetPriceCall,
    });
  });
});

describe('payAmguInEther', () => {
  it('pays for Amgu with ETH correctly', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    const amount = utils.parseEther('1');
    const payAmguTx = engine.payAmguInEther.value(amount).send();

    const frozenEtherAfter = engine.getFrozenEther();
    await expect(frozenEtherAfter).resolves.toEqBigNumber(amount);

    await assertEvent(payAmguTx, 'AmguPaidInEther', {
      amount: amount,
    });
  });
});

describe('thaw', () => {
  it('cannot be called when thawingDelay has not elapsed since lastThaw', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    await engine.payAmguInEther.value(utils.parseEther('1')).send();

    const thawTx = engine.thaw();
    await expect(thawTx).rejects.toBeRevertedWith('Thaw delay has not passed');
  });

  it('cannot be called when frozenEther is 0', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    await warpEngine(provider, engine);

    const thawTx = engine.thaw();
    await expect(thawTx).rejects.toBeRevertedWith('No frozen ether to thaw');
  });

  it('frozenEther is added to liquidEther', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    const amount = utils.parseEther('1');
    await engine.payAmguInEther.value(amount).send();
    await warpEngine(provider, engine);

    const preLiquidEther = await engine.getLiquidEther();
    const thawTx = engine.thaw();

    await assertEvent(thawTx, 'FrozenEtherThawed', {
      amount: amount,
    });

    const postLiquidEther = await engine.getLiquidEther();
    expect(postLiquidEther.sub(preLiquidEther)).toEqBigNumber(amount);

    const frozenEthCall = engine.getFrozenEther();
    await expect(frozenEthCall).resolves.toEqBigNumber(0);
  });
});

describe('etherTakers', () => {
  describe('addEtherTakers', () => {
    it('adds ether taker when called from the Dispatcher owner', async () => {
      const {
        deployment: { engine },
      } = await provider.snapshot(snapshot);

      const newEtherTaker = randomAddress();

      // Assuming the deployer is the Dispatcher owner
      const addEtherTakerTx = engine.addEtherTakers([newEtherTaker]);
      await assertEvent(addEtherTakerTx, 'EtherTakerAdded', {
        etherTaker: newEtherTaker,
      });

      const isEtherTakerCall = engine.isEtherTaker(newEtherTaker);
      await expect(isEtherTakerCall).resolves.toBeTruthy;
    });

    it('reverts when adding an account twice', async () => {
      const {
        deployment: { engine },
      } = await provider.snapshot(snapshot);
      const newEtherTaker = randomAddress();

      const firstAddEtherTakerTx = engine.addEtherTakers([newEtherTaker]);
      await expect(firstAddEtherTakerTx).resolves.toBeReceipt();

      const secondAddEtherTakerTx = engine.addEtherTakers([newEtherTaker]);
      await expect(secondAddEtherTakerTx).rejects.toBeRevertedWith(
        'etherTaker has already been added',
      );
    });

    it('Can only be called by the dispatcher owner', async () => {
      const {
        accounts: { 0: randomUser },
        deployment: { engine },
      } = await provider.snapshot(snapshot);
      const newEtherTaker = randomAddress();

      const addEtherTakerTx = engine
        .connect(randomUser)
        .addEtherTakers([newEtherTaker]);
      await expect(addEtherTakerTx).rejects.toBeRevertedWith(
        'Only the Dispatcher owner can call this function',
      );
    });
  });

  describe('removeEtherTakers', () => {
    it('removes ether taker when called from the dispatcher owner', async () => {
      const {
        deployment: { engine },
      } = await provider.snapshot(snapshot);
      const newEtherTaker = randomAddress();

      await engine.addEtherTakers([newEtherTaker]);

      const removeEtherTakerTx = engine.removeEtherTakers([newEtherTaker]);
      const isEtherTakerCall = engine.isEtherTaker(newEtherTaker);
      await expect(isEtherTakerCall).resolves.toBeFalsy;

      await assertEvent(removeEtherTakerTx, 'EtherTakerRemoved', {
        etherTaker: newEtherTaker,
      });
    });

    it('reverts when removing a non existing account ', async () => {
      const {
        deployment: { engine },
      } = await provider.snapshot(snapshot);
      const newEtherTaker = randomAddress();

      const removeEtherTakerTx = engine.removeEtherTakers([newEtherTaker]);

      await expect(removeEtherTakerTx).rejects.toBeRevertedWith(
        'etherTaker has not been added',
      );
    });

    it('Can only be called by the Dispatcher owner', async () => {
      const {
        accounts: { 0: randomUser },
        deployment: { engine },
      } = await provider.snapshot(snapshot);
      const newEtherTaker = randomAddress();

      const removeEtherTakersTx = engine
        .connect(randomUser)
        .removeEtherTakers([newEtherTaker]);

      await expect(removeEtherTakersTx).rejects.toBeRevertedWith(
        'Only the Dispatcher owner can call this function',
      );
    });
  });
});

describe('calcPremiumPercent', () => {
  it('returns 0 if liquidEther is under 1 ether', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    await seedAndThawEngine(provider, engine, utils.parseEther('0.99'));
    const premiumPercentCall = engine.calcPremiumPercent();

    await expect(premiumPercentCall).resolves.toEqBigNumber(0);
  });

  it('returns 5 if liquidEther is 1 ether', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    await seedAndThawEngine(provider, engine, utils.parseEther('1'));
    const premiumPercentCall = engine.calcPremiumPercent();

    await expect(premiumPercentCall).resolves.toEqBigNumber(5);
  });

  it('returns 10 if liquidEther is 5 ether', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    await seedAndThawEngine(provider, engine, utils.parseEther('5'));
    const premiumPercentCall = engine.calcPremiumPercent();

    await expect(premiumPercentCall).resolves.toEqBigNumber(10);
  });

  it('returns 15 if liquidEther is >= 10 ether', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    await seedAndThawEngine(provider, engine, utils.parseEther('10'));
    const premiumPercentCall = engine.calcPremiumPercent();

    await expect(premiumPercentCall).resolves.toEqBigNumber(15);
  });
});

describe('calcEthOutputForMlnInput', () => {
  it('reverts if MLN/ETH received from ValueInterpreter is not valid rate', async () => {
    const {
      mocks: { mockEngineWithValueInterpreter, mockValueInterpreter },
    } = await snapshotWithMocks(provider);

    await mockValueInterpreter.calcCanonicalAssetValue.returns(0, false);

    const calcEthOutput = mockEngineWithValueInterpreter.calcEthOutputForMlnInput(
      1,
    );
    await expect(calcEthOutput).rejects.toBeRevertedWith(
      'mln to eth rate is invalid',
    );
  });

  it('returns the expected value if the rate received is valid', async () => {
    const {
      mocks: { mockEngineWithValueInterpreter, mockValueInterpreter },
    } = await snapshotWithMocks(provider);
    const expectedOutput = BigNumber.from('1');

    await mockValueInterpreter.calcCanonicalAssetValue.returns(
      expectedOutput,
      true,
    );

    const calcEthOutput = mockEngineWithValueInterpreter.calcEthOutputForMlnInput
      .args(expectedOutput)
      .call();
    await expect(calcEthOutput).resolves.toEqBigNumber(expectedOutput);
  });
});

describe('sellAndBurnMln', () => {
  it('correctly handles selling and burning melon', async () => {
    const {
      config: { deployer },
      deployment: {
        engine,
        tokens: { mln },
      },
    } = await provider.snapshot(snapshot);

    const mlnAmount = utils.parseEther('1');
    const ethAmountWithPremium = utils.parseEther('1.05');
    const deployerAddress = await resolveAddress(deployer);

    await engine.addEtherTakers([deployer]);
    await seedAndThawEngine(provider, engine, ethAmountWithPremium);

    const preMlnBalance = await mln.balanceOf(deployerAddress);
    await mln.approve(engine.address, mlnAmount);

    // Check ETH balance right before doing the tx
    const preEthBalance = await deployer.getBalance();
    const sellAndBurnMlnTx = engine.sellAndBurnMln(mlnAmount);

    const ethGasSpent = (await sellAndBurnMlnTx).gasUsed.mul(
      await deployer.getGasPrice(),
    );

    // Check ETH Balance was received as expected (taking gas into account)
    const postSellEthBalance = await deployer.getBalance();
    expect(postSellEthBalance).toEqBigNumber(
      preEthBalance.sub(ethGasSpent).add(ethAmountWithPremium),
    );

    // Check MLN Balance was spent
    const postMlnBalance = await mln.balanceOf(deployerAddress);
    await expect(postMlnBalance).toEqBigNumber(preMlnBalance.sub(mlnAmount));

    await assertEvent(sellAndBurnMlnTx, 'MlnTokensBurned', {
      amount: mlnAmount,
    });
  });

  it('reverts if sender is not an authorized ether taker', async () => {
    const {
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    const failSellBurnTx = engine.sellAndBurnMln(utils.parseEther('1'));

    await expect(failSellBurnTx).rejects.toBeRevertedWith(
      'only an authorized ether taker can call this function',
    );
  });

  it('reverts if mlnAmount value is greater than available liquidEther', async () => {
    const {
      config: { deployer },
      deployment: { engine },
    } = await provider.snapshot(snapshot);

    const mlnAmount = utils.parseEther('1');
    const ethAmountWithPremium = utils.parseEther('1.04');

    await seedAndThawEngine(provider, engine, ethAmountWithPremium);
    await engine.addEtherTakers([deployer]);

    const failSellBurnTx = engine.sellAndBurnMln(mlnAmount);

    await expect(failSellBurnTx).rejects.toBeRevertedWith(
      'Not enough liquid ether',
    );
  });

  it('reverts if the ETH amount to be sent to the user is zero', async () => {
    const {
      config: { deployer },
      mocks: { mockEngineWithValueInterpreter, mockValueInterpreter },
    } = await provider.snapshot(snapshotWithMocks);

    const mlnAmount = utils.parseEther('1');
    const deployerAddress = await resolveAddress(deployer);

    await mockValueInterpreter.calcCanonicalAssetValue.returns(0, true);
    await mockEngineWithValueInterpreter.addEtherTakers([deployerAddress]);
    const failSellBurnTx = mockEngineWithValueInterpreter.sellAndBurnMln(
      mlnAmount,
    );

    await expect(failSellBurnTx).rejects.toBeRevertedWith(
      'No ether to pay out',
    );
  });
});