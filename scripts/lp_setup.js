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

// ABI Fragments for the ERC20 token and Uniswap Router V2
const tokenABI = [
    "function approve(address spender, uint amount) public returns(bool)",
    "function setTradingEnabled(bool _enabled) public"
];

const routerABI = [
    "function addLiquidityETH(address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity)"
];

// Create Contract Instances
const tokenContract = new ethers.Contract(tokenAddress, tokenABI, wallet);
const routerContract = new ethers.Contract(routerAddress, routerABI, wallet);

// Function to Approve Maximum uint256 for the Uniswap Router V2
async function approveMax() {
    const maxUint = ethers.MaxUint256;
    const tx = await tokenContract.approve(routerAddress, maxUint);
    await tx.wait();
    console.log(`Approval Transaction Hash: ${tx.hash}`);
}

// Function to Enable Trading
async function setTradingEnabled() {
    const tx = await tokenContract.setTradingEnabled(true);
    await tx.wait();
    console.log("Trading enabled on the token contract.");
}

// Function to Add Liquidity to Uniswap
async function addLiquidity() {
    const amountTokenDesired = ethers.parseUnits("100000", 18); // Update decimal as per your token
    const to = '0x9767a2B120614F526e923DAAF89843EC7C2292d7';
    const deadline = (await provider.getBlockNumber()) + 10000000000; // Setting deadline to the next block

    const tx = await routerContract.addLiquidityETH(
        tokenAddress,
        amountTokenDesired,
        0, // amountTokenMin
        0, // amountETHMin
        to,
        deadline,
        { value: ethers.parseEther("0.01") } // Change ETH amount to your desired investment
    );
    await tx.wait();
    console.log(`Liquidity Added Transaction Hash: ${tx.hash}`);
}

// Run the functions
async function main() {
    await approveMax();
    console.log("Approved");
    await setTradingEnabled();
    console.log("Trading Enabled");
    await addLiquidity();
    console.log("Liquidity Added");
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});


