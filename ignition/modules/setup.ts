import { ethers } from "hardhat";

// Asynchronously fetch and export required data
export async function getOwnerAddress() {
    const [owner] = await ethers.getSigners();
    return owner.getAddress();
}
