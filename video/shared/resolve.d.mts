export interface Format { name: string; width: number; height: number; label: string }
export interface Theme {
  name: string; description?: string;
  font: {family: string; fallback: string; css: string; weight?: number; mono?: string};
  colors: {ink: string; muted: string; paper: string; accent: string; card: string; track: string; line: string};
  background: {from: string; to: string};
  device: {wallpaper: {from: string; to: string}; lid: string; baseFrom: string; baseTo: string; thumb: string; windowBar: string; windowBody: string; shadow: number; terminal: 'light' | 'dark'};
  caption: {text: string; outline: string; size: number; box?: boolean; boxColor?: string};
}
export const FORMATS: Record<string, {width: number; height: number; label: string}>;
export const SCENE_TYPES: Record<string, {kind: 'canvas' | 'clip'; minLength: number; designWidth?: number}>;
export function deepMerge<T>(base: T, extra: unknown): T;
export function validateTheme(theme: unknown): string[];
export function buildThemes(builtIn: Record<string, any>, user?: Record<string, any>): Record<string, any>;
export function resolveTheme(themes: Record<string, any>, name?: string, overrides?: unknown): Theme;
export function resolveFormat(name?: string): Format;
export function fitScale(format: {width: number; height: number}, designWidth?: number): number;
export function validateProject(project: any): string[];
export const TRANSITIONS: Record<string, {xfade: string | null; description: string}>;
export const TRANSITION_LENGTH: number;
export function validateTransition(value: unknown, where: string): string[];
export function validateCamera(props: unknown, where: string): string[];
export function isNarrow(format: {width: number; height: number}): boolean;
export interface Captions { burn: boolean; scenes: 'clips' | 'all' | string[]; style: string; border: 'outline' | 'box' | 'shadow' | 'none'; bold: boolean; scale: number; position: 'auto' | 'bottom' | 'top' | 'middle'; font: string; text: string; outline: string; box: string; karaoke: boolean; highlight: string; sidecar: boolean }
export const CAPTION_STYLES: Record<string, {border: string; bold?: boolean; size?: number; karaoke?: boolean; description: string}>;
export const CAPTION_POSITIONS: string[];
export function validateCaptions(cfg: unknown): string[];
export function assColor(hex: string): string;
export function resolveCaptions(args: {theme: Theme; project?: any; adapter?: any; env?: Record<string, string | undefined>}): Captions;
export interface Music { enabled: boolean; track: string | null; sha256: string | null; volume: number; duck: boolean; fadeIn: number; fadeOut: number; start: number; loop: boolean; credit: string | null }
export function validateMusic(raw: unknown): string[];
export function resolveMusic(args: {project?: any; adapter?: any; env?: Record<string, string | undefined>}): Music;
