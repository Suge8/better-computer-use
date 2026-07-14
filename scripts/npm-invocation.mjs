export function npmInvocation(args) {
	if (process.env.npm_execpath) return [process.execPath, [process.env.npm_execpath, ...args]];
	return [process.platform === "win32" ? "npm.cmd" : "npm", args];
}
