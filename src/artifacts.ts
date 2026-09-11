import { chmod, mkdir, readdir, stat, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { ImageInfo, ToolImage } from "./contract.ts";
import { BcuError } from "./errors.ts";

const ARTIFACT_TTL_MS = 10 * 60 * 1_000;
const MAX_ARTIFACTS = 128;
const MAX_ARTIFACT_BYTES = 256 * 1024 * 1024;
const MAX_SCREENSHOT_BYTES = 16 * 1024 * 1024;
const directoryTails = new Map<string, Promise<unknown>>();

export function screenshotDirectory(): string {
	return path.join(os.homedir(), "Library", "Caches", "bcu", "shots");
}

async function remove(filePath: string): Promise<void> {
	await unlink(filePath).catch((error: NodeJS.ErrnoException) => {
		if (error.code !== "ENOENT") throw error;
	});
}

interface ArtifactFile {
	path: string;
	size: number;
	mtimeMs: number;
}

async function artifactFile(filePath: string): Promise<ArtifactFile | undefined> {
	try {
		const metadata = await stat(filePath);
		return { path: filePath, size: metadata.size, mtimeMs: metadata.mtimeMs };
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
		throw error;
	}
}

async function prune(directory: string, preservedPath: string, now = Date.now()): Promise<void> {
	const entries = await readdir(directory, { withFileTypes: true });
	const candidates = await Promise.all(entries
		.filter((entry) => entry.isFile() && /\.(jpg|png)$/.test(entry.name))
		.map(async (entry) => await artifactFile(path.join(directory, entry.name))));
	const files = candidates
		.filter((file): file is ArtifactFile => file !== undefined)
		.sort((left, right) => left.mtimeMs - right.mtimeMs);
	let totalBytes = files.reduce((sum, file) => sum + file.size, 0);
	let totalFiles = files.length;
	for (const file of files) {
		const expired = now - file.mtimeMs > ARTIFACT_TTL_MS;
		const overCapacity = totalFiles > MAX_ARTIFACTS || totalBytes > MAX_ARTIFACT_BYTES;
		if (file.path === preservedPath || (!expired && !overCapacity)) continue;
		await remove(file.path);
		totalBytes -= file.size;
		totalFiles -= 1;
	}
}

async function serializeDirectory<Result>(directory: string, work: () => Promise<Result>): Promise<Result> {
	const previous = directoryTails.get(directory) ?? Promise.resolve();
	const current = previous.catch(() => undefined).then(work);
	directoryTails.set(directory, current);
	try {
		return await current;
	} finally {
		if (directoryTails.get(directory) === current) directoryTails.delete(directory);
	}
}

/** Writes one look image into the artifact directory and returns its public reference. */
export async function saveScreenshot(
	stateId: string,
	image: ToolImage,
	directory = screenshotDirectory(),
): Promise<ImageInfo> {
	if (!/^[A-Za-z0-9_-]+$/.test(stateId)) throw new BcuError("internal_error", `Screenshot stateId '${stateId}' is not a safe artifact name.`);
	const bytes = Buffer.from(image.data, "base64");
	if (bytes.length === 0 || bytes.length > MAX_SCREENSHOT_BYTES) {
		throw new BcuError("internal_error", `Screenshot size ${bytes.length} is outside the supported range.`);
	}
	const artifactDirectory = path.resolve(directory);
	return await serializeDirectory(artifactDirectory, async () => {
		await mkdir(artifactDirectory, { recursive: true, mode: 0o700 });
		await chmod(artifactDirectory, 0o700);
		const extension = image.mimeType === "image/png" ? "png" : "jpg";
		const filePath = path.join(artifactDirectory, `${stateId}.${extension}`);
		await writeFile(filePath, bytes, { mode: 0o600 });
		await chmod(filePath, 0o600);
		await prune(artifactDirectory, filePath);
		return { path: filePath, mime: image.mimeType, width: image.width, height: image.height };
	});
}
