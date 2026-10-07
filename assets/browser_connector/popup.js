for (const command of ['connect', 'refresh']) {
  document.getElementById(command).addEventListener('click', async () => {
    const buttons = document.querySelectorAll('button');
    buttons.forEach(button => {button.disabled = true;});
    const status = document.getElementById('status');
    status.textContent = 'Connecting…';
    try {
      const result = await chrome.runtime.sendMessage({command});
      status.textContent = result?.ok ? 'Connected. Return to Resonance and press Test access.' : result?.error || 'Open Resonance and start connecting first.';
    } catch {
      status.textContent = 'Open Resonance and start connecting first, then try again.';
    } finally {
      buttons.forEach(button => {button.disabled = false;});
    }
  });
}
