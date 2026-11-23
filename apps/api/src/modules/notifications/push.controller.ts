import { Body, Controller, Delete, Get, Header, HttpCode, Post } from '@nestjs/common';
import { z } from 'zod';
import type { AuthUser } from '../../shared/auth/auth.types';
import { CurrentUser, Public } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { PLATFORMS, PushService } from './push.service';

const Register = z.object({ token: z.string().min(20).max(512), platform: z.enum(PLATFORMS) });
const Unregister = z.object({ token: z.string().min(20).max(512) });

/** Notifications sur le téléphone : abonnement des appareils et configuration de la version web. */
@Controller()
export class PushController {
  constructor(private readonly push: PushService) {}

  @Post('v1/me/push-tokens')
  @HttpCode(200)
  register(@CurrentUser() user: AuthUser, @Body() body: unknown) {
    const { token, platform } = parse(Register, body);
    return this.push.register(user.id, token, platform);
  }

  @Delete('v1/me/push-tokens')
  @HttpCode(200)
  unregister(@CurrentUser() user: AuthUser, @Body() body: unknown) {
    return this.push.unregister(user.id, parse(Unregister, body).token);
  }

  @Public()
  @Get('v1/push/config')
  config() {
    return this.push.webConfig();
  }

  /**
   * Service worker de Firebase, à la racine du site (exigé par le navigateur) :
   * affiche les notifications quand l'app web est fermée.
   */
  @Public()
  @Get('firebase-messaging-sw.js')
  @Header('Content-Type', 'application/javascript; charset=utf-8')
  @Header('Cache-Control', 'no-cache')
  serviceWorker() {
    const web = this.push.webConfig().web;
    if (!web) return '// Notifications web non configurées\n';
    const cfg = JSON.stringify({
      apiKey: web.apiKey,
      appId: web.appId,
      projectId: web.projectId,
      messagingSenderId: web.messagingSenderId,
    });
    return `importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');
firebase.initializeApp(${cfg});
firebase.messaging();
// Firebase ouvre lui-même le lien prévu (fcm_options) ; sinon, on ouvre l'app sur le bon écran
self.addEventListener('notificationclick', (event) => {
  const msg = (event.notification.data && event.notification.data.FCM_MSG) || {};
  if (msg.fcmOptions && msg.fcmOptions.link) return;
  const link = (msg.data && msg.data.link) || '/notifications';
  event.notification.close();
  event.waitUntil(clients.openWindow('/app/#' + link));
});
`;
  }
}
