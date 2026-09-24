import { DatabaseSync } from 'node:sqlite';
import { createOwnerAuthority } from '../src/authority.js';
// Only receives synthetic test tokens over private IPC. Never writes tokens.
process.once('message', ({ path, audience, token, request, generationRequest, action, wall, revoke,
  mutationBody, mutationEvidence, credentialId, sessionToken, grantToken }) => {
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
    if (action === 'revoke-credential') core.revokeCredential(token, credentialId, true);
    else if (action === 'claim-credential-mutation') {
      core.claimChallengeCredentialMutation(token, request, Buffer.from(mutationBody, 'base64'));
    }
    else if (action === 'commit-credential-mutation') {
      core.commitChallengeCredentialMutation(token, request, Buffer.from(mutationBody, 'base64'), mutationEvidence);
    }
    else if (action === 'commit-read-route') {
      core.commitChallengeReadRoute(sessionToken, grantToken, request, Buffer.from(mutationBody, 'base64'));
    }
    else if (revoke) core.revokeAll(token, true);
    else if (generationRequest) core.commitGenerationMetadata(token, generationRequest, sessionToken);
    else core.consumeGrant(token, request);
    process.send({ accepted: true });
  } catch (error) {
    process.send({ accepted: false, code: error.code });
  } finally { core?.close(); setImmediate(() => process.disconnect()); }
});
