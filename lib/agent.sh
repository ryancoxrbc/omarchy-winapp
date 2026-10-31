# shellcheck shell=bash
# The agent: the program inside Windows that opens what winapp asks for.
#
# Windows is shown as one desktop in one window, and a file opened from Linux
# is opened in that desktop, not in a connection of its own. winapp writes the
# command line into a folder the desktop's connection redirects, and
# winapp-agent.exe, running in the session, starts it and brings its window to
# the front (guest/agent.cs). The apply job builds it in the VM and registers
# the scheduled task that starts it at every sign-in and connection.

AGENT_SOURCE=$ROOT/guest/agent.cs
AGENT_EXE='C:\ProgramData\winapp\winapp-agent.exe'

agent_stamp() { cksum <"$AGENT_SOURCE" | cut -d' ' -f1; }

# The VM's copy is current when there is nothing to send, and usable when
# requests can be served. One that would not build is recorded as current but
# not usable, so that opening a desktop does not try again every time;
# `winapp setup` does.
agent_current() {
  [[ $(cfg_json | jq -r '.guestAgent | "\(.vm) \(.stamp)"') == "$(vm_identity) $(agent_stamp)" ]]
}
agent_usable() {
  [[ $(cfg_json | jq -r '.guestAgent | "\(.vm) \(.ok)"') == "$(vm_identity) true" ]]
}
agent_record() { # agent_record <true|false>
  cfg_edit '.guestAgent = {vm: $vm, stamp: $stamp, ok: $ok}' \
    --arg vm "$(vm_identity)" --arg stamp "$(agent_stamp)" --argjson ok "$1"
}

# The part of an apply job that builds it in the VM.
agent_job() { jq -cn --arg stamp "$(agent_stamp)" '{agent: {stamp: $stamp}}'; }

# Record what the last apply job said about it.
agent_noted() {
  local status
  status=$(guest_out '.agent.status')
  if [[ $status == ok ]]; then
    agent_record true
  else
    GUEST_ERROR="Windows could not build winapp's agent (${status:-no answer})"
    agent_record false
    return 1
  fi
}
