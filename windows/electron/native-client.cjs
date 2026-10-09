const { EventEmitter } = require("node:events");
const { spawn } = require("node:child_process");

class NativeClient extends EventEmitter {
  constructor(command, args, options = {}) {
    super();
    this.pending = new Map();
    this.sequence = 0;
    this.buffer = "";
    this.closed = false;
    this.child = spawn(command, args, {
      ...options,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk) => {
      this.buffer += chunk;
      if (this.buffer.length > 12 * 1024 * 1024) {
        this.child.kill();
        return;
      }
      let newline;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        try {
          const message = JSON.parse(line);
          if (message.event) this.emit("event", message.event, message.data);
          else if (this.pending.has(message.id)) {
            const pending = this.pending.get(message.id);
            this.pending.delete(message.id);
            clearTimeout(pending.timer);
            if (message.error) pending.reject(new Error(message.error));
            else pending.resolve(message.result);
          }
        } catch {
          this.emit(
            "notice",
            "The Windows helper returned an invalid message.",
          );
        }
      }
    });
    this.child.stderr.on("data", (data) =>
      this.emit("diagnostic", data.toString()),
    );
    const close = (reason) => {
      if (this.closed) return;
      this.closed = true;
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error(reason));
      }
      this.pending.clear();
      this.emit("close", reason);
    };
    this.child.once("error", (error) => close(error.message));
    this.child.once("exit", (code, signal) =>
      close(`Windows helper stopped (${signal || code}).`),
    );
    this.child.stdin.on("error", () => {});
  }
  call(method, args = {}) {
    if (this.closed)
      return Promise.reject(
        new Error("Windows helper is unavailable. Restart the island."),
      );
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("This operation took too long. Try again."));
      }, 45000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ id, method, args }) + "\n");
    });
  }
  close() {
    this.child.stdin.end();
  }
}
module.exports = { NativeClient };
