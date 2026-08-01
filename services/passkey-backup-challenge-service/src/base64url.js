import { isUtf8 } from 'node:buffer';

const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;

export function base64UrlEncode(value) {
  return Buffer.from(value).toString('base64url');
}

export function base64UrlDecode(value, label = 'base64url value', maxEncodedLength = 32768) {
  if (typeof value !== 'string' || value.length === 0 || value.length > maxEncodedLength) {
    throw new Error(`${label} must be a non-empty base64url string`);
  }
  if (!BASE64URL_RE.test(value) || value.length % 4 === 1) {
    throw new Error(`${label} must be base64url encoded without padding`);
  }

  const decoded = Buffer.from(value, 'base64url');
  if (base64UrlEncode(decoded) !== value) {
    throw new Error(`${label} must be canonical base64url`);
  }

  return decoded;
}

export function base64UrlDecodeToUtf8(value, label = 'base64url value') {
  const decoded = base64UrlDecode(value, label, 8192);
  if (!isUtf8(decoded)) {
    throw new Error(`${label} must contain valid UTF-8`);
  }
  return decoded.toString('utf8');
}
