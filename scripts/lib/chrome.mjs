import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import path from "node:path";
import { killProcess, withTimeout } from "./harness.mjs";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/**
 * Starts a dedicated Google Chrome on its own profile with DevTools listening, showing `url`.
 * `onSpawn` receives the handle as soon as the process exists, so cleanup reaches a launch
 * that fails halfway.
 */
export async function launchChrome(profile, url, onSpawn) {
	await fs.mkdir(profile);
	const watcher = fs.watch(profile);
	const child = spawn(CHROME, [
		`--user-data-dir=${profile}`,
		"--remote-debugging-port=0",
		"--no-first-run",
		"--no-default-browser-check",
		"--new-window",
		url,
	], { stdio: "ignore" });
	const chrome = { child, exited: once(child, "exit") };
	onSpawn?.(chrome);
	const portFile = path.join(profile, "DevToolsActivePort");
	const ready = (async () => {
		for (;;) {
			const text = await fs.readFile(portFile, "utf8").catch(() => "");
			const [port, browserPath] = text.split("\n");
			if (port && browserPath) return { port: Number(port), browserPath };
			await watcher.next();
		}
	})();
	try {
		const devtools = await withTimeout(Promise.race([
			ready,
			chrome.exited.then(([code]) => { throw new Error(`Chrome exited during launch (${code})`); }),
		]), "Chrome DevTools to listen", 20_000);
		return Object.assign(chrome, devtools);
	} finally {
		await watcher.return?.();
	}
}

export async function stopChrome(chrome) {
	if (!chrome || !killProcess(chrome.child.pid, "SIGTERM")) return;
	try {
		await withTimeout(chrome.exited, "the fixture Chrome to exit", 5_000);
	} catch {
		if (killProcess(chrome.child.pid, "SIGKILL")) await chrome.exited;
	}
}

/** One DevTools session; `send` resolves with the command result. */
export async function devtoolsSession(url) {
	const socket = new WebSocket(url);
	await new Promise((resolve, reject) => {
		socket.addEventListener("open", resolve, { once: true });
		socket.addEventListener("error", () => reject(new Error(`DevTools socket ${url} failed`)), { once: true });
	});
	let nextId = 0;
	const pending = new Map();
	socket.addEventListener("message", (event) => {
		const message = JSON.parse(event.data);
		const waiter = pending.get(message.id);
		if (!waiter) return;
		pending.delete(message.id);
		if (message.error) waiter.reject(new Error(message.error.message));
		else waiter.resolve(message.result);
	});
	return {
		send(method, params = {}) {
			const id = ++nextId;
			socket.send(JSON.stringify({ id, method, params }));
			return withTimeout(new Promise((resolve, reject) => pending.set(id, { resolve, reject })), `DevTools ${method}`, 10_000);
		},
		close: () => socket.close(),
	};
}

/** The DevTools session of the page showing `url`. */
export async function pageSession(chrome, url) {
	const response = await fetch(`http://127.0.0.1:${chrome.port}/json/list`);
	const page = (await response.json()).find((target) => target.type === "page" && target.url === url);
	if (!page) throw new Error(`Chrome has no page at ${url}`);
	return await devtoolsSession(page.webSocketDebuggerUrl);
}
