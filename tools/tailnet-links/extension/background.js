async function render() {
  const [enabled] = await chrome.declarativeNetRequest.getEnabledRulesets();
  const on = enabled === "tailnet";
  await chrome.action.setBadgeText({ text: on ? "" : "off" });
  await chrome.action.setTitle({ title: `Loops via tailnet: ${on ? "on" : "off"}` });
}

chrome.action.onClicked.addListener(async () => {
  const on = (await chrome.declarativeNetRequest.getEnabledRulesets()).includes("tailnet");
  await chrome.declarativeNetRequest.updateEnabledRulesets(
    on ? { disableRulesetIds: ["tailnet"] } : { enableRulesetIds: ["tailnet"] }
  );
  await render();
});

chrome.runtime.onStartup.addListener(render);
chrome.runtime.onInstalled.addListener(render);
