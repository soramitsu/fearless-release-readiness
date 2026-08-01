export class PasskeyBackupServiceError extends Error {
  constructor(status, code, message = code, details = undefined) {
    super(message);
    this.name = 'PasskeyBackupServiceError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export function serviceError(status, code, message = code, details = undefined) {
  return new PasskeyBackupServiceError(status, code, message, details);
}

export function asServiceError(error) {
  if (error instanceof PasskeyBackupServiceError) {
    return error;
  }

  return new PasskeyBackupServiceError(500, 'internal_error', 'internal_error');
}
