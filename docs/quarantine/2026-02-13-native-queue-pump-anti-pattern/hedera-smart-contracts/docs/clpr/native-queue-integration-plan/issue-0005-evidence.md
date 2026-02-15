# ISSUE-0005 Evidence

Date: 2026-02-12

## Implemented changes (consensus repo)

- Added native enqueue helper:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprQueueOperations.java`
- Removed queue test-seeding shortcut from queue-init path:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`
- Added queue operation tests:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/ClprQueueOperationsTest.java`
- Updated handler test for queue init behavior:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/handler/ClprUpdateMessageQueueMetadataHandlerTest.java`
- Updated CLPR baseline suite expected queue counts after removing synthetic seeding:
  - `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`

## Validation commands and outcomes

### 1) Unit and handler tests

Command:

```bash
./gradlew :hiero-clpr-interledger-service-impl:test \
  --tests org.hiero.interledger.clpr.impl.test.ClprQueueOperationsTest \
  --tests org.hiero.interledger.clpr.impl.test.handler.ClprUpdateMessageQueueMetadataHandlerTest \
  --no-daemon --console=plain
```

Outcome:

- `SUCCESS: Executed 23 tests in 3s`
- `BUILD SUCCESSFUL`

### 2) CLPR subprocess baseline

Command:

```bash
./gradlew :test-clients:testSubprocess \
  --tests com.hedera.services.bdd.suites.interledger.ClprMessagesSuite \
  --rerun-tasks --no-daemon --console=plain
```

Outcome:

- `1 passing (47.8s)`
- `BUILD SUCCESSFUL`

## Key behavioral confirmation

- Queue initialization now starts empty (`nextMessageId=1`, `sentMessageId=0`, `receivedMessageId=0`) instead of synthetic 10-message preload.
- Native enqueue operation assigns monotonic message ids and stores running-hash progression in `ClprMessageValue`.
- Enqueue operation validates:
  - non-empty ledger id,
  - payload contains `message` or `message_reply`,
  - queue metadata exists for target remote ledger.
