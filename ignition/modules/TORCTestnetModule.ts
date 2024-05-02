import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("TORC", (m) => {

  const torc = m.contract("TORC", []);

  return { torc }; 
});
  