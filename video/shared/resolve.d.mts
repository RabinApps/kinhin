export interface Format { name: string; width: number; height: number; label: string }
export interface Theme {
  name: string; description?: string;
  font: {family: string; fallback: string; css: string; weight?: number; mono?: string};
  colors: {ink: string; muted: string; paper: string; accent: string; card: string; track: string; line: string};
  background: {from: string; to: string};
  device: {wallpaper: {from: string; to: string}; lid: string; baseFrom: string; baseTo: string; thumb: string; windowBar: string; windowBody: string; shadow: number};
  caption: {text: string; outline: string; size: number; box?: boolean; boxColor?: string};
}
export const FORMATS: Record<string, {width: number; height: number; label: string}>;
export const SCENE_TYPES: Record<string, {kind: 'canvas' | 'clip'; minLength: number}>;
export function deepMerge<T>(base: T, extra: unknown): T;
export function resolveTheme(themes: Record<string, any>, name?: string, overrides?: unknown): Theme;
export function resolveFormat(name?: string): Format;
export function fitScale(format: {width: number; height: number}): number;
export function validateProject(project: any): string[];
