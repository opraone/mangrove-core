// SPDX-License-Identifier:	AGPL-3.0
pragma solidity ^0.8.13;

import {Deployer} from "mgv_script/lib/Deployer.sol";
import {Test2, console2 as console} from "mgv_lib/Test2.sol";
import {MgvReader, VolumeData, IMangrove} from "mgv_src/periphery/MgvReader.sol";
import {IERC20} from "mgv_src/IERC20.sol";
import {MgvStructs} from "mgv_src/MgvLib.sol";

/**
 * @notice Script to obtain data about a given mangrove offer list. Data is outputted to terminal as space separated values.
 * @notice output is a json file with the following structure:
 *  {
 *   "blockNumber": <number>, // the block number at which data are collected
 *   "totalVolume": <number>, // the max volume for the analysis
 *   "failingIds": [ // the id of the offers that were failing at this block
 *     <offerID>, ...
 *   ],
 *   "gas_used_for_volume": <number>, // the total gas cost for a market order of "Total volume" (arbitrary price)
 *   "data_1": ...
 *   ...
 *   "data_i": { // data_i is a market order consumming i offers of the book
 *     "bounty": <number>, // collected bounty after i offers were consummed
 *     "distance_to_density": <float>, distance to min density if market order was a single offer of "volume_sent" and "gas_req". In display units of outbound tokens.
 *     "successes": <number>, number (<=i) of successful offers
 *     "failures": <number>, number (<= i - successes) of failed offers
 *     "gas_fail": <number>, gas consummed to snipe failing offers
 *     "gas_req": <number>, gas required by offer makers
 *     "gas_used": <number>, approx of the gas used for this market order
 *     "volume_received": <float>, amount of outbound tokens received (in display units)
 *     "volume_sent": <float>, amount of inbount tokens sent (in display unit)
 *   }
 *   ...
 * }
 * @notice environment variables that control the script are:
 * @param VOLUME the amount of outbound token that are required from the market
 * @param TKN_IN the inbound token (token that are sent by the tester)
 * @param TKN_OUT the outbound token (token that are required by the tester)
 */
/**
 * Usage: testing status of buy orders on the WMATIC,USDT market for volumes of up to 100,000 WMATIC (display units)
 *  VOLUME=$(cast ff 18 100000) TKN_IN=USDT TKN_OUT=WMATIC \
 *  forge script --fork-url mumbai MarketHealth
 */
contract MarketHealth is Test2, Deployer {
  // needed if some offer fail, in order to receive bounty
  uint[] internal failingIds;

  receive() external payable {}

  function run() public {
    IERC20 inbTkn = IERC20(envAddressOrName("TKN_IN"));
    // dealing hopefully enough inbound token to execute a market order
    deal(address(inbTkn), address(this), 10_000_000 * 10 ** inbTkn.decimals());
    innerRun({
      mgv: IMangrove(envAddressOrName("MGV", "Mangrove")),
      reader: MgvReader(envAddressOrName("MGV_READER", "MgvReader")),
      inbTkn: inbTkn,
      outTkn: IERC20(envAddressOrName("TKN_OUT")),
      outboundTknVolume: vm.envUint("VOLUME")
    });
  }

  struct HeapVars {
    uint outDecimals;
    uint inbDecimals;
    uint required;
    VolumeData[] data;
    uint got;
    uint snipesGot;
    uint gave;
    uint snipesGave;
    uint successes;
    uint snipesSuccesses;
    uint failures;
    uint collected;
    uint snipesBounty;
    uint gasFail;
    uint gasSpent;
    uint gasbase;
    uint best;
    uint takerWants;
    uint[4][] targets;
    uint g;
    MgvStructs.OfferPacked offer;
    string rootKey;
    string dataKey;
    uint[] failingIds;
    string distanceToDensity;
    uint minVolume;
  }

  function innerRun(IMangrove mgv, MgvReader reader, IERC20 inbTkn, IERC20 outTkn, uint outboundTknVolume) public {
    HeapVars memory vars;
    vars.data =
      reader.marketOrder(address(outTkn), address(inbTkn), outboundTknVolume, inbTkn.balanceOf(address(this)), true);
    vars.outDecimals = outTkn.decimals();
    vars.inbDecimals = inbTkn.decimals();
    // inbound volume required (if not offer is failing)
    vars.required = vars.data[vars.data.length - 1].totalGave;
    // multipliying required by 2 in case some offer fail and entails slippage
    deal(address(inbTkn), address(this), vars.required * 2);
    inbTkn.approve(address(mgv), type(uint).max);

    (, MgvStructs.LocalPacked local) = mgv.config(address(outTkn), address(inbTkn));
    vars.gasbase = local.offer_gasbase();

    uint snapshotId = vm.snapshot();
    vars.rootKey = "root_key";
    vm.serializeUint(vars.rootKey, "blockNumber", block.number);
    vm.serializeString(vars.rootKey, "totalVolume", toFixed(outboundTknVolume, vars.outDecimals));

    while (vars.got < outboundTknVolume) {
      vars.dataKey = string.concat("data_", vm.toString(vars.successes + vars.failures));
      vars.best = mgv.best(address(outTkn), address(inbTkn));
      if (vars.best == 0) {
        break;
      }
      vars.offer = mgv.offers(address(outTkn), address(inbTkn), vars.best);
      vars.targets = new uint256[4][](1);
      vars.takerWants =
        vars.offer.gives() + vars.got > outboundTknVolume ? outboundTknVolume - vars.got : vars.offer.gives();
      // offering a better price than what the offer requires
      vars.targets[0] = [vars.best, vars.takerWants, vars.offer.wants(), type(uint).max];
      _gas();
      (vars.snipesSuccesses, vars.snipesGot, vars.snipesGave, vars.snipesBounty,) =
        mgv.snipes(address(outTkn), address(inbTkn), vars.targets, true);
      vars.g = gas_(true);
      if (vars.snipesBounty > 0) {
        // adding gas cost of snipe to gasCost if snipe failed
        vars.gasFail += vars.g;
        failingIds.push(vars.best);
      }
      vars.gasSpent += vars.g - 30_000; // compensating for snipe instead of market order
      vars.successes += vars.snipesSuccesses;
      vars.failures = vars.snipesSuccesses == 0 ? vars.failures + 1 : vars.failures;
      vars.got += vars.snipesGot;
      vars.gave += vars.snipesGave;
      vars.collected += vars.snipesBounty;

      vars.minVolume =
        reader.minVolume(address(outTkn), address(inbTkn), vars.data[vars.successes + vars.failures - 1].totalGasreq);

      if (vars.got > vars.minVolume) {
        vars.distanceToDensity = toFixed(vars.got - vars.minVolume, vars.outDecimals);
      } else {
        vars.distanceToDensity = string.concat("-", toFixed(vars.minVolume - vars.got, vars.outDecimals));
      }

      vm.serializeString(vars.dataKey, "volume_received", toFixed(vars.got, vars.outDecimals));
      vm.serializeString(vars.dataKey, "volume_sent", toFixed(vars.gave, vars.inbDecimals));
      vm.serializeUint(vars.dataKey, "successes", vars.successes);
      vm.serializeUint(vars.dataKey, "failures", vars.failures);
      vm.serializeUint(vars.dataKey, "bounty", vars.collected);
      vm.serializeUint(vars.dataKey, "gas_fail", vars.gasFail);
      vm.serializeUint(vars.dataKey, "gas_used", vars.gasSpent);
      vm.serializeUint(vars.dataKey, "gas_req", vars.data[vars.successes + vars.failures - 1].totalGasreq);
      vars.dataKey = vm.serializeString(vars.dataKey, "distance_to_density", vars.distanceToDensity);
      vm.serializeString(
        vars.rootKey, string.concat("data_", vm.toString(vars.successes + vars.failures)), vars.dataKey
      );
    }
    // revert will discard storage change, saving them
    vars.failingIds = new uint[](failingIds.length);
    for (uint i; i < failingIds.length; i++) {
      vars.failingIds[i] = failingIds[i];
    }
    require(vm.revertTo(snapshotId), "snapshot restore failed");
    _gas();
    mgv.marketOrder(address(outTkn), address(inbTkn), outboundTknVolume, type(uint160).max, true);
    vars.gasSpent = gas_(true);
    vm.serializeUint(vars.rootKey, "failingIds", vars.failingIds);
    vars.rootKey = vm.serializeUint(vars.rootKey, "gas_used_for_volume", vars.gasSpent);
    vm.writeJson(
      vars.rootKey, string.concat("./analytics/data_", outTkn.symbol(), "_", inbTkn.symbol(), "_", fork.NAME(), ".json")
    );
  }
}
