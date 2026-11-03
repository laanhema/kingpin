// The Pi extension a spawned worker loads with -e (bin/kingpin-spawn's pi arm).
// Pi loads it through jiti, so TypeScript needs no build step. The behaviour lives
// in lib/pi-harness.mjs, where the unit suite can drive it with a fake Pi API; this
// file only hands Pi the factory.
import { registerPiHarness } from "../../lib/pi-harness.mjs";

export default function (pi: any) {
  registerPiHarness(pi);
}
