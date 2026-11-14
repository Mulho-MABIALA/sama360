import { v7 } from 'uuid';

/** UUID v7 : triable dans le temps, générable hors ligne côté mobile. */
export const newId = (): string => v7();
