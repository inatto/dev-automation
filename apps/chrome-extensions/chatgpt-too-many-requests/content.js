(() => {
  "use strict";

  const dialogTitle = /too\s+many\s+requests/i;
  const gotItLabel = /^got\s+it$/i;
  const clickedButtons = new WeakSet();

  function isVisible(element) {
    const style = window.getComputedStyle(element);
    const box = element.getBoundingClientRect();
    return style.display !== "none"
      && style.visibility !== "hidden"
      && style.opacity !== "0"
      && box.width > 0
      && box.height > 0;
  }

  function hasRateLimitDialog(button) {
    const dialog = button.closest('[role="dialog"]');
    if (dialog) {
      return dialogTitle.test(dialog.innerText || dialog.textContent || "");
    }

    // Fallback for dialog implementations that do not expose role="dialog".
    let parent = button.parentElement;
    for (let level = 0; parent && level < 6; level += 1) {
      const text = parent.innerText || parent.textContent || "";
      if (dialogTitle.test(text)) return true;
      parent = parent.parentElement;
    }

    return false;
  }

  function dismissRateLimitDialog() {
    const buttons = document.querySelectorAll("button");

    for (const button of buttons) {
      const label = (button.innerText || button.textContent || "").trim();
      if (!gotItLabel.test(label) || !isVisible(button) || clickedButtons.has(button)) {
        continue;
      }

      if (hasRateLimitDialog(button)) {
        clickedButtons.add(button);
        button.click();
        return;
      }
    }
  }

  const observer = new MutationObserver(dismissRateLimitDialog);
  observer.observe(document.documentElement, { childList: true, subtree: true });

  dismissRateLimitDialog();
  window.setInterval(dismissRateLimitDialog, 5000);
})();
