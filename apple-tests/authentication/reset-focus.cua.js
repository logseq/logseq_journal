// Run in cua_repl against the local AuthenticationProbe.
// Precondition: use the UI to sign in with dummy values, return to sign in,
// then choose Forgot password? with the retained username still populated.
// This checks native focus and keyboard submission, not authentication decisions.
var authenticationSimulator = await cua.getApp("com.apple.iphonesimulator");
async function authenticationState() {
  return await authenticationSimulator.getAXState({disableDiffing: true, emit: false});
}
function authenticationElement(state, pattern) {
  const line = state.split("\n").find(line => pattern.test(line));
  if (!line) throw new Error("Missing native element: " + pattern + "\n" + state);
  return Number(line.trim().match(/^\d+/)[0]);
}
var resetState = await authenticationState();
authenticationElement(resetState, /heading Description: Reset your password/);
await authenticationSimulator.click(authenticationElement(resetState, /button Description: go, ID: Go/));
resetState = await authenticationState();
await authenticationSimulator.setValue(
  authenticationElement(resetState, /text field .*Value: Verification code/), "123456");
resetState = await authenticationState();
await authenticationSimulator.click(authenticationElement(resetState, /button Description: next, ID: Next:/));
resetState = await authenticationState();
await authenticationSimulator.click(authenticationElement(resetState, /button s$/));
resetState = await authenticationState();
authenticationElement(resetState, /secure text field .*Value: •.*Placeholder: New password/);
await authenticationSimulator.click(authenticationElement(resetState, /button Description: go, ID: Go/));
resetState = await authenticationState();
authenticationElement(resetState, /heading Description: Sign in to Logseq/);
nodeRepl.write("PASS native reset Go submission, code Next focus, secure input and password Go submission");
