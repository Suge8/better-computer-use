export function trimOrUndefined(value: string | undefined): string | undefined {
	if (typeof value !== "string") return undefined;
	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : undefined;
}

export function normalizeText(value: string | undefined): string {
	return (value ?? "").trim().toLowerCase();
}
