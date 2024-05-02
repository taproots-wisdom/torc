import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("WETH", (m) => {

    const weth = m.contract("WETH", []);
  
    return { weth }; 
});