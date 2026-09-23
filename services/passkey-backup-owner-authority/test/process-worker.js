import { DatabaseSync } from 'node:sqlite';
import { createOwnerAuthority } from '../src/authority.js';
// Only receives synthetic test tokens over private IPC. Never writes tokens.
process.once('message', ({ path, audience, token, request, action, wall, revoke }) => {
  let core;
  if (action === 'hold-lock') {
    const db = new DatabaseSync(path); db.exec('BEGIN IMMEDIATE');
    process.send({ locked: true });
    setTimeout(() => { db.exec('COMMIT'); db.close(); process.disconnect(); }, 250);
    return;
  }
  try {
    core = createOwnerAuthority({ path, audience, now: () => wall, monotonic: () => 0,
      fault(stage) {
        if (action === 'crash-before' && stage === 'beforeCommit') process.exit(81);
        if (action === 'crash-after' && stage === 'afterCommit') process.exit(82);
      },
    });
    if (revoke) core.revokeAll(token);
    else core.consumeGrant(token, request);
    process.send({ accepted: true });
  } catch (error) {
    process.send({ accepted: false, code: error.code });
  } finally { core?.close(); setImmediate(() => process.disconnect()); }
});
