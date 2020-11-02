if (!process.env.MAINNET_ARCHIVE_NODE) {
  console.warn('=====================================================');
  console.warn('WARNING: Skipping end-to-end tests.');
  console.warn('');
  console.warn('You must specify a mainnet archive node endpoint (MAINNET_ARCHIVE_NODE) to run the end-to-end tests.');
  console.warn('=====================================================');
}

const mnemonic = 'test test test test test test test test test test test junk';

function common(name, roots) {
  return {
    displayName: name,
    roots,
    preset: '@crestproject/hardhat',
    globals: {
      'ts-jest': {
        babelConfig: true,
        diagnostics: false,
      },
    },
  };
}

function fork(name, roots) {
  return {
    ...common(name, roots),
    testEnvironmentOptions: {
      hardhatNetworkOptions: {
        // loggingEnabled: true,
        gas: 9500000,
        accounts: {
          mnemonic,
          count: 5,
        },
        forking: {
          url: process.env.MAINNET_ARCHIVE_NODE,
          enabled: true,
          blockNumber: 11091788,
        },
      },
    },
  };
}

function unit(name, roots) {
  return {
    ...common(name, roots),
    testEnvironmentOptions: {
      hardhatNetworkOptions: {
        // loggingEnabled: true,
        gas: 9500000,
        accounts: {
          mnemonic,
          count: 10,
        },
      },
    },
  };
}

const projects = [
  unit('core', ['tests/release/core', 'tests/persistent', 'tests/mocks']),
  unit('infrastructure', ['tests/release/infrastructure']),
  unit('policy', ['tests/release/extensions/policy-manager']),
  unit('integration', ['tests/release/extensions/integration-manager']),
  unit('fee', ['tests/release/extensions/fee-manager']),
  process.env.MAINNET_ARCHIVE_NODE && fork('e2e', ['tests/release/e2e']),
].filter((project) => !!project);

module.exports = {
  testTimeout: 240000,
  projects,
};