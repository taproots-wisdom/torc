const { expect } = require("chai");
const { ethers, ignition } = require("hardhat");
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';

import TorcModule from "../ignition/modules/TORCTestnetModule";
import WETHModule from '../ignition/modules/WETHModule';

import {
    abi as FACTORY_ABI,
    bytecode as FACTORY_BYTECODE,
  } from '@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json'

  import {
    abi as LP_ABI,
    bytecode as LP_BYTECODE,
    } from '@uniswap/v3-core/artifacts/contracts/UniswapV3Pool.sol/UniswapV3Pool.json'

function encodePriceSqrt(reserve1: Number, reserve0: Number) {
    return ethers.BigNumber(reserve1)
        .div(ethers.BigNumber(reserve0))
        .sqrt()
        .multipliedBy(ethers.BigNumber(2).pow(96))
        .integerValue(3)
        .toString()
}

// type MintFunction = (
//     recipient,
//     tickLower,
//     tickUpper,
//     liquidity
//   ) => Promise<ContractTransaction>;

describe("TORC", function () {

    async function deployModuleFixture() {
        const torc = await ignition.deploy(TorcModule); 
        const weth = await ignition.deploy(WETHModule);       

        const UniswapV3 = await ethers.getContractFactory(FACTORY_ABI, FACTORY_BYTECODE);
        const uniswapV3 = await UniswapV3.deploy();
        // await uniswapV3.deployed();

        const [owner] = await ethers.getSigners();
        const ownerAddress = await owner.getAddress();

        return { torc, owner, ownerAddress, uniswapV3, weth };
    }

    beforeEach(async () => {
        // Set up initial conditions or deployments here
    });

    afterEach(async () => {
    // Clean up any modifications made in the beforeEach hook
    });

    // it("Should set the Uniswap Router", async function () {
    //     const { torc } = await loadFixture(deployModuleFixture);

    //     const uniswapRouter = await torc.torc.getUniswapRouterV2Address();
    //     expect(uniswapRouter).to.equal("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D");
    // });

    it("Should distribute the initial supply to the correct addresses", async function () {
        const { torc, ownerAddress } = await loadFixture(deployModuleFixture);

        // const taxAddress = await torc.torc.taxAddress();
        const treasuryAddress = await torc.torc.treasuryWallet();
        const devAddress = await torc.torc.devWallet();
        const teamAddress = await torc.torc.teamWallet();

        // expect(taxAddress).to.equal(ownerAddress);
        expect(treasuryAddress).to.equal("0xD335c5E36F1B19AECE98b78e9827a9DF76eE29E6");
        expect(devAddress).to.equal("0xE4eEc0C7e825f988aEEe7d05BE579519532E94E5");
        expect(teamAddress).to.equal("0x000000000000000000000000000000000000dEaD");

        const taxBalance = await torc.torc.balanceOf(ownerAddress);
        const treasuryBalance = await torc.torc.balanceOf(treasuryAddress);
        const devBalance = await torc.torc.balanceOf(devAddress);
        const teamBalance = await torc.torc.balanceOf(teamAddress);

        const decimals = 18n;
        const initialSupply = 432000000n * 10n ** decimals;

        expect(taxBalance).to.equal(172800000n * 10n ** decimals); 
        expect(treasuryBalance).to.equal(129_600_000n * 10n ** decimals);
        expect(devBalance).to.equal(86_400_000n * 10n ** decimals);
        expect(teamBalance).to.equal(43_200_000n * 10n ** decimals);

        expect(taxBalance + treasuryBalance + devBalance + teamBalance).to.equal(initialSupply);

    });

    it("Should initialize the liquidity pool", async function () {
        const { torc, owner, ownerAddress, uniswapV3, weth } = await loadFixture(deployModuleFixture);
        
        const maxUint = ethers.MaxUint256;
        const tx = await torc.approve(routerAddress, maxUint);
        await tx.wait();
        console.log(`Approval Transaction Hash: ${tx.hash}`);

        // const amountETH = ethers.parseEther("1");
        // const sendEther = await owner.sendTransaction({ to: weth.weth, value: amountETH });
        // await sendEther.wait();

        // expect(await ethers.provider.getBalance(weth.weth)).to.be.at.least(amountETH);

        // expect(await ethers.provider.getBalance(torc.torc)).to.equal(amountETH);

        // const decimals = 9n;
        // const initialSupply = 432000000n * 10n ** decimals;
        // const contractBalance = await torc.torc.balanceOf(torc.torc);
        // expect(contractBalance).to.equal(initialSupply - 332000000000000000n);

        // console.log(uniswapV3)
        const pool = await uniswapV3.createPool(torc.torc, weth.weth, 3000);
        const createPoolReceipt = await pool.wait();
        console.log(createPoolReceipt.hash);
        console.log(createPoolReceipt.logs);
        
        const event = createPoolReceipt.logs.map((log) => uniswapV3.interface.parseLog(log))
        console.log(event[0].args[4]);

        // const price = encodePriceSqrt(1, 2)
       // await pool.initialize(1000000)

        // const { sqrtPriceX96, observationIndex } = await pool.slot0()
        // console.log(sqrtPriceX96.toString(), observationIndex.toString())

        const lp = new ethers.Contract(event[0].args[4], LP_ABI, owner);
        
        const torcBalance = await torc.torc.balanceOf(ownerAddress);
        console.log(torcBalance.toString());

        // await ethers.contractTransaction(lp, 'mint', [ownerAddress, -887220, 887220, 3161]);
        // await mint(ownerAddress, minTick, maxTick, 3161)

        console.log(lp);

        const addLiquidity = await lp.mint(ownerAddress, -887220, 887220, amountETH, "0x");
        const addLiquidityReceipt = await addLiquidity.wait();
        console.log(addLiquidityReceipt);
    });

});