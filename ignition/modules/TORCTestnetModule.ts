import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("TORC", (m) => {
  
    const UNISWAP_ROUTER = "0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008";

    const OWNER_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const TAX_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const TREASURY_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const DEV_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const MARKETING_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const TEAM_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    const torc = m.contract("TORC", [UNISWAP_ROUTER, TAX_ADDRESS, TREASURY_ADDRESS, DEV_ADDRESS, MARKETING_ADDRESS, TEAM_ADDRESS]);
  
    return { torc }; 
  });