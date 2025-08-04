import { ethers } from "hardhat";
import { Ignition } from "@nomicfoundation/hardhat-ignition";

async function main() {
  const [deployer, ...investors] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  const TORC = await ethers.getContractFactory("TORC");

  const ignition = new Ignition(ethers.provider, deployer);

  const deployment = ignition.deploy(TORC, {
    args: []
  });

  const deployed = await ignition.run(deployment);

  console.log("TORC deployed to:", deployed.address);

  // Set investor wallets
  for (let i = 0; i < 4; i++) {
    await deployed.setInvestorWallet(i, investors[i].address);
  }

  return deployed;
}

export default main;
