const { ethers } = require("ethers");
const { config } = require("dotenv");
const path = require('path');

config({ path: path.resolve(__dirname, "../.env") });

const MY_ALCHEMY_RPC_ENDPOINT='https://eth-sepolia.g.alchemy.com/v2/';

const deployerPK = process.env.DEPLOYER_PK ?? "NO_DEPLOYER_PK"; 
const prodDeployerPK = process.env.PROD_DEPLOYER_PK ?? "NO_PROD_DEPLOYER_PK";

// get the network in use and choose the deployer private key accordingly
const ALCHEMY_API_KEY = "xkGEIcnGr7t4Y2t_hYouXDViirM-_3hc";

let deployerPrivateKey = deployerPK;

if (MY_ALCHEMY_RPC_ENDPOINT.includes("mainnet")) {
    // deployerPrivateKey = deployerPK;
    console.log("Mainnet");
}

// Configuration: Set up your provider and wallet
const provider = new ethers.JsonRpcProvider(MY_ALCHEMY_RPC_ENDPOINT + ALCHEMY_API_KEY);
// const privateKey = deployerPK;
const wallet = new ethers.Wallet(deployerPrivateKey, provider);

// Contract Addresses
const tokenAddress = '0xac8b8faAD68867C125F72384e31D07daE40D6fcd';
const routerAddress = '0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008';

const routerABI = [
    "function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline) external payable returns (uint[] memory amounts)",
    "function WETH() external pure returns (address)"
];

// Create Contract Instance for Uniswap Router
const routerContract = new ethers.Contract(routerAddress, routerABI, wallet);

// Function to Swap ETH for Tokens
async function swapETHForTokens() {
    const amountETH = ethers.parseEther("0.0001");
    const wethAddress = await routerContract.WETH(); // Retrieving the WETH address dynamically
    const path = [wethAddress, tokenAddress]; // AddressZero is typically used to denote ETH in Uniswap paths
    const to = wallet.address; // Where the tokens will be sent
    const deadline = (await provider.getBlockNumber()) + 10000000000000; // Adjust deadline reasonably

    const tx = await routerContract.swapExactETHForTokens(
        0, // amountOutMin, set to 0 for simplicity in this example, but should be estimated in a real scenario
        path,
        to,
        deadline,
        { value: amountETH }
    );
    await tx.wait();
    console.log(`Swap Transaction Hash: ${tx.hash}`);
}

// Run the swap function
async function main() {
    await swapETHForTokens();
    console.log("Swap Completed");
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});