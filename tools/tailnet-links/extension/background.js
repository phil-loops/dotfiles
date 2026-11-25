const REDIRECT = 2;

async function tailnetHost() {
  const res = await fetch(chrome.runtime.getURL("tailnet-host"));
  return (await res.text()).trim();
}

function rules(host) {
  return [
    {
      id: 1,
      priority: 2,
      action: { type: "allow" },
      condition: { regexFilter: "^https://app\\.loops\\.so/api/", resourceTypes: ["main_frame"] },
    },
    {
      id: REDIRECT,
      priority: 1,
      action: { type: "redirect", redirect: { regexSubstitution: `https://${host}/\\1` } },
      condition: { regexFilter: "^https://app\\.loops\\.so/(.*)$", resourceTypes: ["main_frame"] },
    },
  ];
}

async function isOn() {
  return (await chrome.declarativeNetRequest.getDynamicRules()).some((r) => r.id === REDIRECT);
}

async function setOn(on) {
  const removeRuleIds = (await chrome.declarativeNetRequest.getDynamicRules()).map((r) => r.id);
  const addRules = on ? rules(await tailnetHost()) : [];
  await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds, addRules });
  await chrome.storage.local.set({ off: !on });
  await chrome.action.setBadgeText({ text: on ? "" : "off" });
  await chrome.action.setTitle({ title: `Loops via tailnet: ${on ? "on" : "off"}` });
}

async function restore() {
  const { off } = await chrome.storage.local.get("off");
  await setOn(!off);
}

chrome.action.onClicked.addListener(async () => setOn(!(await isOn())));
chrome.runtime.onStartup.addListener(restore);
chrome.runtime.onInstalled.addListener(restore);
