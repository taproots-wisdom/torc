// import "hardhat";
import '@nomicfoundation/hardhat-ignition';
import "@nomicfoundation/hardhat-chai-matchers";
// import "@openzeppelin/hardhat-upgrades";
import "@nomiclabs/hardhat-solhint";
import "@nomicfoundation/hardhat-verify";
import "hardhat-abi-exporter";
// import "hardhat-deploy";
import "hardhat-gas-reporter";
// import '@typechain/hardhat'
import '@nomicfoundation/hardhat-ethers'
// import '@nomicfoundation/hardhat-chai-matchers'
import "@nomicfoundation/hardhat-ignition-ethers";
import { resolve } from "path";
import { config as dotenvConfig } from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import { NetworkUserConfig } from "hardhat/types";
// import "@ericxstone/hardhat-blockscout-verify";


dotenvConfig({ path: resolve(__dirname, "./.env") });

const DATAHUB_API_KEY = process.env.DATAHUB_API_KEY || "";
const FUJI_PRIVATE_KEY = process.env.FUJI_PRIVATE_KEY || "";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "";
const COINMARKETCAP_API_KEY = process.env.COINMARKETCAP_API_KEY || "";
const MATICVIGIL_API_KEY = process.env.MATICVIGIL_API_KEY || "";
const POLYGONSCAN_API_KEY = process.env.POLYGONSCAN_API_KEY || "";
const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY || "";
const INFURA_API_KEY = process.env.INFURA_API_KEY || ""; 
const BUILDBEAR_SERVER = process.env.BUILDBEAR_SERVER || "";

const chainIds = {
  goerli: 5,
  hardhat: 1337,
  kovan: 42,
  mainnet: 1,
  rinkeby: 4,
  ropsten: 3,
  polygon: 137,
  polygonMumbai: 80001,
  fuji: 43113,
  avalanche: 43114,
  sepolia: 11155111,
  buildbear: 14075
};

// Ensure that we have all the environment variables we need.
const deployerPK = process.env.DEPLOYER_PK ?? "NO_DEPLOYER_PK"; 
const prodDeployerPK = process.env.PROD_DEPLOYER_PK ?? "NO_PROD_DEPLOYER_PK";

function getChainConfig(network: keyof typeof chainIds): NetworkUserConfig {
  const url = getChainRPC(network);
  let deployer = deployerPK;

  if ((network === "mainnet" || network === "polygon" || network === "avalanche" || network == "buildbear") && prodDeployerPK !== "NO_PROD_DEPLOYER_PK") {
    deployer = prodDeployerPK;
  }

  // Accounts
  const accounts = [deployer];

  return {
      accounts: accounts,
      chainId: chainIds[network],
      url,
      gasPrice: 50000000000,
      gas: 5000000
  };
}

function getChainRPC(network: keyof typeof chainIds): string {
  switch (network) {
    case "mainnet":
    case "rinkeby":
    case "ropsten":
      return `https://eth-${network}.alchemyapi.io/v2/${ALCHEMY_API_KEY}`;
    case "sepolia":
    case "goerli":
      return `https://${network}.infura.io/v3/${INFURA_API_KEY}`;
    case "polygon":
      return `https://polygon-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`;
    case "polygonMumbai":
      return `https://polygon-mumbai.g.alchemy.com/v2/${ALCHEMY_API_KEY}`;
    case "fuji":
      return `https://avalanche--${network}--rpc.datahub.figment.io/apikey/${DATAHUB_API_KEY}/ext/bc/C/rpc`;
    case "avalanche":
      return `https://avalanche--mainnet--rpc.datahub.figment.io/apikey/${DATAHUB_API_KEY}/ext/bc/C/rpc`;
    case "buildbear":
      return `https://rpc.buildbear.io/${BUILDBEAR_SERVER}`;
    default:
      return "";
  }
}

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545"
    },        
    hardhat: {
        mining: {
          auto: true,
          // interval: 2000 // milliseconds
        },
        chainId: chainIds.hardhat,          
        loggingEnabled: process.env.EVM_LOGGING === "true",
        // forking: {
        //   url: getChainRPC("mainnet"),
        //   blockNumber: 19069705
        // },
        
    },   
    mainnet: getChainConfig("mainnet"),
    rinkeby: getChainConfig("rinkeby"),
    ropsten: getChainConfig("ropsten"),
    goerli: getChainConfig("goerli"),
    sepolia: getChainConfig("sepolia"),
    polygon: getChainConfig("polygon"),
    polygonMumbai: getChainConfig("polygonMumbai"),
    avalanche: getChainConfig("avalanche"),
    fuji: getChainConfig("fuji"),
    buildbear: getChainConfig("buildbear"),       
  },
  gasReporter: {
    currency: 'USD',
    token: 'ETH',
    showMethodSig: true,
    showTimeSpent: true,
    enabled: process.env.REPORT_GAS ? true : false,
    excludeContracts: [],
    src: "./contracts",
    coinmarketcap: COINMARKETCAP_API_KEY,
  },

  etherscan: {
    apiKey: {
      polygonMumbai: POLYGONSCAN_API_KEY,
      polygon: POLYGONSCAN_API_KEY,
      mainnet: ETHERSCAN_API_KEY,
      rinkeby: ETHERSCAN_API_KEY,
      goerli: ETHERSCAN_API_KEY,
      sepolia: ETHERSCAN_API_KEY,
      buildbear: "verifyContrats",     
    },
    customChains: [
      {
        network: "buildbear",
        chainId: chainIds["buildbear"],
        urls: {
          apiURL:`https://rpc.buildbear.io/verify/etherscan/${BUILDBEAR_SERVER}`,
          browserURL: `https://explorer.buildbear.io/node/${BUILDBEAR_SERVER}`,
        },
      },
    ],
  },
  solidity: {
    compilers: [
      {
        version: "0.8.9",
        settings: {
          metadata: {
            bytecodeHash: "none",
          },
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
      {
        version: "0.8.16",
        settings: {
          metadata: {
            bytecodeHash: "none",
          },
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
      {
        version: "0.8.17",
        settings: {
          metadata: {
            bytecodeHash: "none",
          },
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },      
      {
        version: "0.8.20",
        settings: {
          metadata: {
            bytecodeHash: "none",
          },
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
      {
        version: "0.8.24",
        settings: {
          metadata: {
            bytecodeHash: "none",
          },
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      }
    ],
    settings: {
        outputSelection: {
            "*": {
                "*": ["storageLayout"],
            },
        },
    },
  },
//   namedAccounts: {
//     deployer: {
//         default: 0,
//     }
// },
  // typechain: {
  //   outDir: "types",
  //   target: "ethers-v5",
  // },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./test",
},
  mocha: {
    timeout: 40000
  },
  abiExporter: {
    path: './abi',
    clear: true,
    flat: true,
    // only: [':ERC20$'],
    spacing: 2,
    // pretty: true,
  },
};

export default config; 
