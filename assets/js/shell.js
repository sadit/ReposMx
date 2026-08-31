/* ReposMx — consola web (shell TUI en el navegador), con historial de comandos persistente */

document.addEventListener('DOMContentLoaded', () => {
  const termInput = document.getElementById('term-input');
  const termOutput = document.getElementById('term-output');

  let shellHistory = [];
  try {
    shellHistory = JSON.parse(localStorage.getItem('reposmx_shell_history') || '[]');
  } catch (e) {
    shellHistory = [];
  }
  let historyCursor = -1;
  let tempCurrentInput = '';

  termInput.addEventListener('keydown', async (e) => {
    if (e.key === 'ArrowUp') {
      e.preventDefault();
      if (shellHistory.length === 0) return;
      if (historyCursor === -1) {
        tempCurrentInput = termInput.value;
      }
      if (historyCursor < shellHistory.length - 1) {
        historyCursor++;
        termInput.value = shellHistory[shellHistory.length - 1 - historyCursor];
      }
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (historyCursor > 0) {
        historyCursor--;
        termInput.value = shellHistory[shellHistory.length - 1 - historyCursor];
      } else if (historyCursor === 0) {
        historyCursor = -1;
        termInput.value = tempCurrentInput;
      }
    } else if (e.key === 'Enter') {
      const cmd = termInput.value.trim();
      if (!cmd) return;

      if (shellHistory.length === 0 || shellHistory[shellHistory.length - 1] !== cmd) {
        shellHistory.push(cmd);
        if (shellHistory.length > 200) shellHistory.shift();
        try {
          localStorage.setItem('reposmx_shell_history', JSON.stringify(shellHistory));
        } catch (e) {}
      }
      historyCursor = -1;
      tempCurrentInput = '';

      termOutput.textContent += `\nreposmx> ${cmd}\n`;
      termInput.value = '';
      termOutput.scrollTop = termOutput.scrollHeight;

      if (cmd === '/clear' || cmd === 'clear') {
        termOutput.textContent = '';
        return;
      }

      try {
        const res = await fetch(`/api/cli/execute?cmd=${encodeURIComponent(cmd)}`);
        const data = await res.json();
        termOutput.textContent += (data.output || '') + '\n';
        termOutput.scrollTop = termOutput.scrollHeight;
      } catch (err) {
        termOutput.textContent += '[Error de conexión con el servidor]\n';
      }
    }
  });
});
