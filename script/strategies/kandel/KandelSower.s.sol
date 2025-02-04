// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {GeometricKandel} from "mgv_src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {AbstractKandelSeeder} from "mgv_src/strategies/offer_maker/market_making/kandel/KandelSeeder.sol";
import {MgvStructs} from "mgv_src/MgvLib.sol";
import {IMangrove} from "mgv_src/IMangrove.sol";
import {IERC20} from "mgv_src/IERC20.sol";
import {Deployer} from "mgv_script/lib/Deployer.sol";
import {MangroveTest, Test} from "mgv_test/lib/MangroveTest.sol";

/**
 * @notice deploys a Kandel instance on a given market
 * @dev since the max number of price slot Kandel can use is an immutable, one should deploy Kandel on a large price range.
 * @dev Example: WRITE_DEPLOY=true BASE=WETH QUOTE=USDC GASPRICE_FACTOR=10 COMPOUND_RATE_BASE=100 COMPOUND_RATE_QUOTE=100 forge script --fork-url $LOCALHOST_URL KandelDeployer --broadcast --private-key $MUMBAI_PRIVATE_KEY
 */

contract KandelSower is Deployer {
  function run() public {
    bool onAave = vm.envBool("ON_AAVE");
    innerRun({
      mgv: IMangrove(envAddressOrName("MGV", "Mangrove")),
      kandelSeeder: AbstractKandelSeeder(
        envAddressOrName("KANDEL_SEEDER", onAave ? fork.get("AaveKandelSeeder") : fork.get("KandelSeeder"))
        ),
      base: IERC20(envAddressOrName("BASE")),
      quote: IERC20(envAddressOrName("QUOTE")),
      gaspriceFactor: vm.envUint("GASPRICE_FACTOR"), // 10 means cover 10x the current gasprice of Mangrove
      sharing: vm.envBool("SHARING"),
      onAave: onAave,
      registerNameOnFork: true,
      name: envHas("NAME") ? vm.envString("NAME") : ""
    });
    outputDeployment();
  }

  /**
   * @param mgv The Mangrove Kandel will trade on
   * @param kandelSeeder The address of the (Aave)KandelSeeder
   * @param base The base token of the market Kandel will act on
   * @param quote The quote token of the market Kandel will act on
   * @param gaspriceFactor multiplier of Mangrove's gasprice used to compute Kandel's provision
   * @param sharing whether the deployed (aave) Kandel should allow shared liquidity
   * @param onAave whether AaveKandel should be deployed instead of Kandel
   * @param registerNameOnFork whether to register the Kandel instance on the fork.
   * @param name The name to register the deployed Kandel instance under. If empty, a name will be generated
   */
  function innerRun(
    IMangrove mgv,
    AbstractKandelSeeder kandelSeeder,
    IERC20 base,
    IERC20 quote,
    uint gaspriceFactor,
    bool sharing,
    bool onAave,
    bool registerNameOnFork,
    string memory name
  ) public {
    (MgvStructs.GlobalPacked global,) = mgv.config(address(0), address(0));

    broadcast();
    GeometricKandel kdl = kandelSeeder.sow(
      AbstractKandelSeeder.KandelSeed({
        base: base,
        quote: quote,
        gasprice: global.gasprice() * gaspriceFactor,
        liquiditySharing: sharing
      })
    );

    if (registerNameOnFork) {
      string memory kandelName = getName(name, base, quote, onAave);
      fork.set(kandelName, address(kdl));
    }

    smokeTest(kdl, onAave);
  }

  function getName(string memory name, IERC20 base, IERC20 quote, bool onAave) public view returns (string memory) {
    if (bytes(name).length > 0) {
      return name;
    } else {
      string memory baseName = onAave ? "AaveKandel_" : "Kandel_";
      return string.concat(baseName, base.symbol(), "_", quote.symbol());
    }
  }

  function smokeTest(GeometricKandel kdl, bool onAave) internal {
    require(kdl.admin() == broadcaster(), "Incorrect admin for Kandel");
    require(onAave || address(kdl.router()) == address(0), "Incorrect router");
  }
}
