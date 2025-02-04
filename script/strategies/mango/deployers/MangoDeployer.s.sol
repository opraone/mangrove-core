// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Mango, IERC20, IMangrove} from "mgv_src/strategies/offer_maker/market_making/mango/Mango.sol";
import {Deployer} from "mgv_script/lib/Deployer.sol";

/**
 * @notice deploys a Mango instance on a given market
 */
/**
 * First test:
 *  forge script
 *  NAME=<optional name in case symbols are ambiguous>
 *  BASE=WETH \
 *  QUOTE=0x<quote_address> \
 *  --fork-url mumbai MangoDeployer -vvv
 *
 * e.g deploy mango on WETH <quote> market:
 *
 *   WRITE_DEPLOY=true \
 *   BASE=WETH QUOTE=USDC BASE_0=$(cast ff 18 1) QUOTE_0=$(cast ff 6 800)\
 *   NSLOTS=100 PRICE_INCR=$(cast ff 6 10)\
 *   DEPLOYER=$MUMBAI_TESTER_ADDRESS\
 *   forge script --fork-url $LOCAL_URL  MangoDeployer --broadcast\
 *   --broadcast \
 *   MangoDeployer
 */

contract MangoDeployer is Deployer {
  Mango public current;

  function run() public {
    innerRun({
      mgv: IMangrove(envAddressOrName("MGV", "Mangrove")),
      base: IERC20(envAddressOrName("BASE")),
      quote: IERC20(envAddressOrName("QUOTE")),
      base_0: vm.envUint("BASE_0"),
      quote_0: vm.envUint("QUOTE_0"),
      nslots: vm.envUint("NSLOTS"),
      price_incr: vm.envUint("PRICE_INCR"),
      admin: envAddressOrName("DEPLOYER"),
      name: envHas("NAME") ? vm.envString("NAME") : ""
    });
    outputDeployment();
  }

  /**
   * @param mgv The Mangrove that Mango will trade on
   * @param base The base currency of the market Mango will act upon
   * @param quote The quote currency of Mango's market
   * @param base_0 in units of base. Amounts of initial `makerGives` for Mango's asks
   * @param quote_0 in units of quote. Amounts of initial `makerGives` for Mango's bids
   * @notice min price of Mango is determined by `quote_0/base_0`
   * @param nslots the number of price slots of the Mango strat
   * @param price_incr in units of quote. Price(i+1) = price(i) + price_incr
   * @param admin address of the adim on Mango after deployment
   * @param name The name to register the deployed Kandel instance under. If empty, a name will be generated
   */
  function innerRun(
    IMangrove mgv,
    IERC20 base,
    IERC20 quote,
    uint base_0,
    uint quote_0,
    uint nslots,
    uint price_incr,
    address admin,
    string memory name
  ) public {
    broadcast();
    console.log(broadcaster(), broadcaster().balance);
    current = new Mango(
      mgv,
      base,
      quote,
      base_0,
      quote_0,
      nslots,
      price_incr,
      admin
    );
    string memory mangoName = getName(name, base, quote);
    fork.set(mangoName, address(current));
  }

  function getName(string memory name, IERC20 base, IERC20 quote) public view returns (string memory) {
    if (bytes(name).length > 0) {
      return name;
    } else {
      return string.concat("Mango_", base.symbol(), "_", quote.symbol());
    }
  }
}
