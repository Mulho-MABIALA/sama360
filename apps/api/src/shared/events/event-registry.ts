import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { DiscoveryService, MetadataScanner, Reflector } from '@nestjs/core';
import type { DomainEvent } from '@sama360/contracts';
import type { Tx } from '../db/db.service';
import { DOMAIN_EVENT_HANDLER } from './on-domain-event.decorator';

export interface RegisteredHandler {
  name: string; // « Classe.methode »
  type: string;
  run: (event: DomainEvent, tx: Tx) => Promise<void>;
}

/** Découvre au démarrage toutes les méthodes décorées par @OnDomainEvent. */
@Injectable()
export class EventRegistry implements OnModuleInit {
  private readonly logger = new Logger(EventRegistry.name);
  private readonly byName = new Map<string, RegisteredHandler>();
  private readonly byType = new Map<string, RegisteredHandler[]>();

  constructor(
    private readonly discovery: DiscoveryService,
    private readonly scanner: MetadataScanner,
    private readonly reflector: Reflector,
  ) {}

  onModuleInit(): void {
    for (const wrapper of this.discovery.getProviders()) {
      const instance = wrapper.instance as Record<string, unknown> | undefined;
      if (!instance || typeof instance !== 'object') continue;
      const proto = Object.getPrototypeOf(instance);
      for (const method of this.scanner.getAllMethodNames(proto)) {
        const fn = proto[method];
        const type = this.reflector.get<string>(DOMAIN_EVENT_HANDLER, fn);
        if (!type) continue;
        const name = `${instance.constructor.name}.${method}`;
        const handler: RegisteredHandler = {
          name,
          type,
          run: (event, tx) => (fn as (e: DomainEvent, t: Tx) => Promise<void>).call(instance, event, tx),
        };
        this.byName.set(name, handler);
        this.byType.set(type, [...(this.byType.get(type) ?? []), handler]);
      }
    }
    this.logger.log(`${this.byName.size} abonné(s) d'événements enregistré(s)`);
  }

  handlersFor(type: string): RegisteredHandler[] {
    return this.byType.get(type) ?? [];
  }

  get(name: string): RegisteredHandler | undefined {
    return this.byName.get(name);
  }
}
