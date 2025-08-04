const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TORC Token", function () {
    let TORC, torc, owner, addr1, addr2, investors, earthWallet, ownerWallet;
    const DEV_WALLET_SUPPLY = ethers.parseEther("86400000");
    const TEAM_WALLET_SUPPLY = ethers.parseEther("43200000");
    const TREASURY_WALLET_SUPPLY = ethers.parseEther("19600000");
    const LIQUID_POOL_SUPPLY = ethers.parseEther("172800000");

    beforeEach(async function () {
        // Deploy the contract
        // TORC = await ethers.getContractFactory("TORC");
        [owner, addr1, addr2, ...investors] = await ethers.getSigners();
        torc = await ethers.deployContract("TORC");
        console.log("TORC deployed to:", torc.address);
        console.log(torc)
        // await torc.deployed();

        // Set investor wallets
        for (let i = 0; i < 4; i++) {
            await torc.setInvestorWallet(i, investors[i].address);
        }
        earthWallet = await torc.earthWallet();
        ownerWallet = await torc.ownerWallet();
    });

    it("Should assign the total supply of tokens to the owner", async function () {
        const ownerBalance = await torc.balanceOf(owner.address);
        expect(LIQUID_POOL_SUPPLY).to.equal(ownerBalance);
    });

    it("Should distribute tokens correctly during mint", async function () {
        const totalSupply = await torc.totalSupply();

        // Check initial balances
        const treasuryBalance = await torc.balanceOf(await torc.treasuryWallet());
        const devBalance = await torc.balanceOf(await torc.devWallet());
        const teamBalance = await torc.balanceOf(await torc.teamWallet());
        const ownerBalance = await torc.balanceOf(owner.address);

        expect(treasuryBalance).to.equal(totalSupply/(3n));
        expect(devBalance).to.equal(totalSupply/(5n));
        expect(teamBalance).to.equal(totalSupply/(10n));
        expect(ownerBalance).to.equal(totalSupply/(2n).add(totalSupply/(5n))); // 40% + 20%
    });

    it("Should transfer tokens between accounts", async function () {
        // Transfer 50 tokens from owner to addr1
        await torc.transfer(addr1.address, 50);
        const addr1Balance = await torc.balanceOf(addr1.address);
        expect(addr1Balance).to.equal(50);

        // Transfer 50 tokens from addr1 to addr2
        await torc.connect(addr1).transfer(addr2.address, 50);
        const addr2Balance = await torc.balanceOf(addr2.address);
        expect(addr2Balance).to.equal(50);
    });

    it("Should take fees on sell", async function () {
        // Transfer tokens to addr1 and then to pair (simulate sell)
        // enable trading
        await torc.setTradingEnabled(true);
        await torc.transfer(addr1.address, 1000);
        await torc.connect(addr1).transfer(torc.uniswapV2Pair(), 1000);

        // Check fees
        const fee = (await torc.sellFee()) * 1000 / 10000;
        const balanceContract = await torc.balanceOf(torc.address);
        expect(balanceContract).to.equal(fee);
    });

    it("Should distribute ETH correctly on swap and liquify", async function () {
        // Simulate a swap and liquify
        await torc.transfer(torc.address, 1000);
        await torc.swapAndLiquify();

        // Check investor and wallet balances
        const ethBalanceInvestors = [];
        let totalEth = await ethers.provider.getBalance(torc.address);
        for (let i = 0; i < 4; i++) {
            ethBalanceInvestors.push(await ethers.provider.getBalance(investors[i].address));
            totalEth -= ethBalanceInvestors[i];
        }
        const ethBalanceEarth = await ethers.provider.getBalance(earthWallet);
        const ethBalanceOwner = await ethers.provider.getBalance(ownerWallet);

        expect(totalEth).to.be.closeTo(0, 1e15); // small tolerance for gas fees
        expect(ethBalanceEarth).to.be.above(0);
        expect(ethBalanceOwner).to.be.above(0);
    });

    it("Should exclude and include wallets from fees", async function () {
        // Exclude addr1 from fees
        await torc.excludeFromFee(addr1.address);
        expect(await torc.isExcludedFromFee(addr1.address)).to.be.true;

        // Include addr1 back in fees
        await torc.includeInFee(addr1.address);
        expect(await torc.isExcludedFromFee(addr1.address)).to.be.false;
    });

    it("Should correctly update investor details", async function () {
        // Update investor wallet
        await torc.setInvestorWallet(0, addr1.address);
        expect((await torc.investors(0)).wallet).to.equal(addr1.address);

        // Update investor cut
        await torc.setInvestorCut(0, 500); // 5%
        expect((await torc.investors(0)).cut).to.equal(500);

        // Update investor enabled status
        await torc.setInvestorEnabled(0, false);
        expect((await torc.investors(0)).enabled).to.be.false;
    });

    it("Should correctly handle allowances", async function () {
        // Approve addr1 to spend tokens on behalf of owner
        await torc.approve(addr1.address, 100);
        expect(await torc.allowance(owner.address, addr1.address)).to.equal(100);

        // Increase allowance
        await torc.increaseAllowance(addr1.address, 50);
        expect(await torc.allowance(owner.address, addr1.address)).to.equal(150);

        // Decrease allowance
        await torc.decreaseAllowance(addr1.address, 50);
        expect(await torc.allowance(owner.address, addr1.address)).to.equal(100);
    });

    it("Should only allow owner to set investor details and manage fees", async function () {
        // Try setting investor wallet from non-owner account
        await expect(torc.connect(addr1).setInvestorWallet(0, addr2.address)).to.be.revertedWith("Ownable: caller is not the owner");

        // Try excluding from fee from non-owner account
        await expect(torc.connect(addr1).excludeFromFee(addr2.address)).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should recover ETH from the contract", async function () {
        // Transfer some ETH to the contract
        await owner.sendTransaction({ to: torc.address, value: ethers.utils.parseEther("1") });

        // Recover ETH from contract
        await torc.recoverETHfromContract();
        const treasuryBalance = await ethers.provider.getBalance(torc.treasuryWallet());
        expect(treasuryBalance).to.be.above(ethers.utils.parseEther("0.9")); // Tolerance for gas fees
    });

    it("Should recover ERC20 tokens from the contract", async function () {
        // Deploy another ERC20 token
        const ERC20 = await ethers.getContractFactory("ERC20Token");
        const erc20 = await ERC20.deploy();
        await erc20.deployed();

        // Transfer some tokens to the TORC contract
        await erc20.transfer(torc.address, 1000);

        // Recover tokens from contract
        await torc.recoverTokensFromContract(erc20.address, 1000);
        const treasuryBalance = await erc20.balanceOf(torc.treasuryWallet());
        expect(treasuryBalance).to.equal(1000);
    });

    it("Should allow owner to set trading enabled", async function () {
        // Enable trading
        await torc.setTradingEnabled(true);
        expect(await torc.tradingEnabled()).to.be.true;

        // Disable trading
        await torc.setTradingEnabled(false);
        expect(await torc.tradingEnabled()).to.be.false;
    });

    it("Should revert transfer when trading is disabled", async function () {
        // Disable trading
        await torc.setTradingEnabled(false);

        // Try transferring tokens
        await expect(torc.transfer(addr1.address, 50)).to.be.revertedWith("Trading is disabled");

        // Enable trading and try again
        await torc.setTradingEnabled(true);
        await torc.transfer(addr1.address, 50);
        const addr1Balance = await torc.balanceOf(addr1.address);
        expect(addr1Balance).to.equal(50);
    });
});
