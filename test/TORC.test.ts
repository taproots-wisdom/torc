const { expect } = require("chai");
const { ethers, ignition } = require("hardhat");
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';

import TorcModule from "../ignition/modules/TORCTestnetModule";



describe("TORC", function () {

    async function deployModuleFixture() {

        const torc = await ignition.deploy(TorcModule);        

        const [owner] = await ethers.getSigners();
        const ownerAddress = await owner.getAddress();

        return { torc, owner, ownerAddress };
    }

    beforeEach(async () => {
        // Set up initial conditions or deployments here
    });

    afterEach(async () => {
    // Clean up any modifications made in the beforeEach hook
    });

    it("Should set the Uniswap Router", async function () {
        const { torc } = await loadFixture(deployModuleFixture);

        const uniswapRouter = await torc.torc.getUniswapRouterV2Address();
        expect(uniswapRouter).to.equal("0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008");
    });

    it("Should distribute the initial supply to the correct addresses", async function () {
        const { torc, ownerAddress } = await loadFixture(deployModuleFixture);

        const taxAddress = await torc.torc.getTaxAddress();
        const treasuryAddress = await torc.torc.getTreasuryAddress();
        const devAddress = await torc.torc.getDevAddress();
        const marketingAddress = await torc.torc.getMarketingAddress();
        const teamAddress = await torc.torc.getTeamAddress();

        expect(taxAddress).to.equal(ownerAddress);
        expect(treasuryAddress).to.equal(ownerAddress);
        expect(devAddress).to.equal(ownerAddress);
        expect(marketingAddress).to.equal(ownerAddress);
        expect(teamAddress).to.equal(ownerAddress);

        // call the distribute function
        const distribute = await torc.torc.distributeInitialBalances();
        await distribute.wait();

        const taxBalance = await torc.torc.balanceOf(taxAddress);
        const treasuryBalance = await torc.torc.balanceOf(treasuryAddress);
        const devBalance = await torc.torc.balanceOf(devAddress);
        const marketingBalance = await torc.torc.balanceOf(marketingAddress);
        const teamBalance = await torc.torc.balanceOf(teamAddress);

        const decimals = 9n;
        const initialSupply = 432000000n * 10n ** decimals;

        expect(taxBalance).to.equal(332000000000000000n);
        expect(treasuryBalance).to.equal(332000000000000000n);
        expect(devBalance).to.equal(332000000000000000n);
        expect(marketingBalance).to.equal(332000000000000000n);
        expect(teamBalance).to.equal(332000000000000000n);

        expect(await torc.torc.balanceOf(torc.torc)).to.equal(initialSupply - 332000000000000000n);


    });

    it("Should receive ether in the contract", async function () {
        const { torc, owner } = await loadFixture(deployModuleFixture);

        const amount = ethers.parseEther("1");
        await owner.sendTransaction({ to: torc.torc, value: amount });

        expect(await ethers.provider.getBalance(torc.torc)).to.equal(amount);
    });

    it("Should initialize the liquidity pool", async function () {
        const { torc, owner } = await loadFixture(deployModuleFixture);

        const distribution = await torc.torc.distributeInitialBalances();
        await distribution.wait();

        const amount = ethers.parseEther("1");
        const sendEther = await owner.sendTransaction({ to: torc.torc, value: amount });
        await sendEther.wait();

        const lp = await torc.torc.initLP();
        await lp.wait();
    });

});