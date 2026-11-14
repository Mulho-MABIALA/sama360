import { Global, Module } from '@nestjs/common';
import { DiscoveryModule } from '@nestjs/core';
import { EventRegistry } from './event-registry';
import { EventWorkerService } from './event-worker.service';
import { OutboxRelayService } from './outbox-relay.service';
import { OutboxService } from './outbox.service';

/**
 * OutboxService est utilisé partout (API) pour enregistrer des événements.
 * OutboxRelayService et EventWorkerService ne sont démarrés que dans le process
 * worker (src/worker.ts) ou explicitement dans les tests.
 */
@Global()
@Module({
  imports: [DiscoveryModule],
  providers: [OutboxService, EventRegistry, OutboxRelayService, EventWorkerService],
  exports: [OutboxService, EventRegistry, OutboxRelayService, EventWorkerService],
})
export class EventsModule {}
