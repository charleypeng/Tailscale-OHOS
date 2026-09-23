import { PeerPathResult } from '../services/StreamingModels';

@Component
export struct DeviceDetailSheet {
  @Prop online: boolean = false;
  @Prop meshConnected: boolean = false;
  @Prop path: PeerPathResult = { type: 'unknown', checkedAt: 0 };
  @Prop tailscaleAddress: string = '';
  @Prop exitNodeCapable: boolean = false;
  @Prop servicesChecking: boolean = false;
  @Prop showSunshine: boolean = false;
  @Prop sunshineState: string = 'unknown';
  @Prop sunshineAvailable: boolean = false;
  @Prop sunshineLaunching: boolean = false;
  @Prop mediaServiceCount: number = 0;
  @Prop mediaServiceNames: string = '';
  @Prop mediaLaunching: boolean = false;
  @Prop serviceRefreshVisible: boolean = false;
  @Prop localSendState: string = 'unknown';
  @Prop localSendRefreshing: boolean = false;
  @Prop localSendAvailable: boolean = false;
  @Prop taildropAvailable: boolean = false;
  @Prop taildropOnline: boolean = false;
  @Prop taildropReady: boolean = false;
  @Prop remoteFilesEnabled: boolean = false;
  onRefresh: () => Promise<void> = async (): Promise<void> => {};
  onOpenStream: () => void = () => {};
  onOpenMedia: () => void = () => {};
  onOpenFileTransfer: () => void = () => {};
  onOpenRemoteFiles: () => void = () => {};
  onCopyIp: () => void = () => {};

  private sunshineLabel(): ResourceStr {
    if (!this.online) {
      return $r('app.string.device_detail_device_offline');
    }
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (this.servicesRefreshing()) {
      return $r('app.string.transfer_protocol_refreshing');
    }
    if (this.sunshineState === 'available') {
      return $r('app.string.device_detail_service_available');
    }
    if (this.sunshineState === 'unknown' || this.sunshineState === 'checking') {
      return $r('app.string.device_status_unknown');
    }
    return $r('app.string.device_detail_service_unavailable');
  }

  private sunshineStatusState(): string {
    if (!this.online) {
      return 'offline';
    }
    if (!this.meshConnected) {
      return 'disconnected';
    }
    if (this.servicesRefreshing()) {
      return 'checking';
    }
    return this.sunshineState === 'available' ? 'available' : 'unavailable';
  }

  private localSendLabel(): ResourceStr {
    if (!this.online) {
      return $r('app.string.device_detail_device_offline');
    }
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (this.servicesRefreshing()) {
      return $r('app.string.transfer_protocol_refreshing');
    }
    if (this.localSendAvailable || this.localSendState === 'available') {
      return $r('app.string.device_detail_service_available');
    }
    if (this.localSendState === 'unknown' || this.localSendState === 'checking') {
      return $r('app.string.device_status_unknown');
    }
    return $r('app.string.device_detail_service_unavailable');
  }

  private localSendStatusState(): string {
    if (!this.online) {
      return 'offline';
    }
    if (!this.meshConnected) {
      return 'disconnected';
    }
    if (this.servicesRefreshing()) {
      return 'checking';
    }
    if (this.localSendAvailable || this.localSendState === 'available') {
      return 'available';
    }
    return 'unavailable';
  }

  private taildropLabel(): ResourceStr {
    if (!this.online) {
      return $r('app.string.device_detail_device_offline');
    }
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (this.servicesRefreshing()) {
      return $r('app.string.transfer_protocol_refreshing');
    }
    return this.taildropReady ? $r('app.string.device_detail_service_available') :
      $r('app.string.device_detail_service_unavailable');
  }

  private taildropStatusState(): string {
    if (!this.online) {
      return 'offline';
    }
    if (!this.meshConnected) {
      return 'disconnected';
    }
    if (this.servicesRefreshing()) {
      return 'checking';
    }
    return this.taildropReady ? 'available' : 'unavailable';
  }

  private mediaLabel(): ResourceStr {
    if (!this.online) {
      return $r('app.string.device_detail_device_offline');
    }
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (this.servicesRefreshing()) {
      return $r('app.string.transfer_protocol_refreshing');
    }
    return this.mediaServiceCount > 0 ?
      $r('app.string.device_detail_media_discovered', this.mediaServiceNames) :
      $r('app.string.device_detail_service_unavailable');
  }

  private mediaStatusState(): string {
    if (!this.online) {
      return 'offline';
    }
    if (!this.meshConnected) {
      return 'disconnected';
    }
    if (this.servicesRefreshing()) {
      return 'checking';
    }
    return this.mediaServiceCount > 0 ? 'available' : 'unavailable';
  }

  private taildriveLabel(): ResourceStr {
    if (!this.online) {
      return $r('app.string.device_detail_device_offline');
    }
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (this.servicesRefreshing()) {
      return $r('app.string.transfer_protocol_refreshing');
    }
    return this.remoteFilesEnabled ? $r('app.string.device_detail_service_available') :
      $r('app.string.device_detail_service_unavailable');
  }

  private taildriveStatusState(): string {
    if (!this.online) {
      return 'offline';
    }
    if (!this.meshConnected) {
      return 'disconnected';
    }
    if (this.servicesRefreshing()) {
      return 'checking';
    }
    return this.remoteFilesEnabled ? 'available' : 'unavailable';
  }

  private servicesRefreshing(): boolean {
    // The sheet that renders the spinner and capsules owns their visible state.
    // Parent polling and background probes cannot toggle it asynchronously.
    return this.serviceRefreshVisible;
  }

  private hasFileTransferAction(): boolean {
    return this.taildropReady || this.localSendAvailable;
  }

  private hasServiceActions(): boolean {
    if (!this.meshConnected) {
      return false;
    }
    return this.sunshineAvailable || this.mediaServiceCount > 0 || this.hasFileTransferAction() ||
      (this.online && this.remoteFilesEnabled);
  }

  private async refreshServices(): Promise<void> {
    if (!this.meshConnected || !this.online || this.servicesRefreshing()) {
      return;
    }
    try {
      await this.onRefresh();
    } catch (_error) {
      // A failed service must not leave the unified sheet state latched.
    }
  }

  private pathLabel(): ResourceStr {
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (!this.online) {
      return $r('app.string.peer_offline');
    }
    if (this.path.type === 'direct') {
      return $r('app.string.device_path_direct', this.path.latencyMs ?? 0);
    }
    if (this.path.type === 'peerRelay') {
      return $r('app.string.device_path_peer_relay', this.path.latencyMs ?? 0);
    }
    if (this.path.type === 'derp') {
      return $r('app.string.device_path_derp_relay', this.path.latencyMs ?? 0);
    }
    if (this.path.type === 'unreachable') {
      return $r('app.string.device_path_unreachable');
    }
    return $r('app.string.device_status_unknown');
  }

  @Builder
  private SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ left: 4, top: 4, bottom: 0 })
  }

  @Builder
  private StatusCapsule(label: ResourceStr, state: string) {
    Stack({ alignContent: Alignment.End }) {
      Text(label)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(state === 'available' ? $r('app.color.status_success') :
          state === 'checking' ? $r('app.color.status_warning') :
            $r('sys.color.font_secondary'))
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .backgroundColor(state === 'available' ? '#1837B77A' :
          state === 'checking' ? '#18F59E0B' : '#12000000')
        .borderRadius(12)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 116 })
    }
    .width(116)
    .height(28)
    .align(Alignment.End)
  }

  @Builder
  private ServiceStatusRow(title: ResourceStr, label: ResourceStr, state: string) {
    Row({ space: 12 }) {
      Text(title)
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      this.StatusCapsule(label, state)
    }
    .width('100%')
    .height(42)
    .padding({ left: 12, right: 12 })
  }

  @Builder
  private CompactAction(icon: Resource, title: ResourceStr, loading: boolean, action: () => void) {
    Button({
      type: ButtonType.Normal,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL,
      controlSize: ControlSize.SMALL
    }) {
      Row({ space: 5 }) {
        if (loading) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.emphasize'))
        } else {
          SymbolGlyph(icon)
            .fontSize(18)
            .fontColor([$r('app.color.emphasize')])
        }
        Text(title)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .layoutWeight(1)
    .height(54)
    .padding({ left: 6, right: 6, top: 4, bottom: 4 })
    .backgroundColor($r('app.color.surface_subtle'))
    .border({ width: 1, color: $r('app.color.divider_subtle') })
    .borderRadius(7)
    .enabled(!loading)
    .opacity(loading ? 0.58 : 1)
    .onClick(() => {
      if (!loading) {
        action();
      }
    })
  }

  @Builder
  private InfoRow(label: ResourceStr, value: ResourceStr, actionable: boolean,
    action: () => void = () => {}) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(value)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
      if (actionable) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('sys.color.icon_secondary')])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .onClick(() => {
      if (actionable) {
        action();
      }
    })
  }

  @Builder
  private CopyInfoRow(label: ResourceStr, value: ResourceStr, action: () => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(value)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
      SymbolGlyph($r('sys.symbol.square_on_square_fill'))
        .fontSize(16)
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .onClick(action)
  }

  build() {
    Scroll() {
      Column({ space: 8 }) {
        Row() {
          Text($r('app.string.device_detail_services_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .padding({ left: 4, top: 4, bottom: 0 })
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            if (this.servicesRefreshing()) {
              LoadingProgress()
                .width(17)
                .height(17)
                .color($r('sys.color.icon_secondary'))
            } else {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(17)
                .fontColor([$r('sys.color.icon_secondary')])
            }
          }
          .width(32)
          .height(32)
          .enabled(this.meshConnected && this.online && !this.servicesRefreshing())
          .opacity(this.meshConnected && this.online ? 1 : 0.45)
          .accessibilityText($r('app.string.device_detail_refresh_services'))
          .onClick(() => this.refreshServices())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Column({ space: 0 }) {
          if (this.showSunshine) {
            this.ServiceStatusRow('Sunshine', this.sunshineLabel(), this.sunshineStatusState())
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: 14, right: 14 })
          }
          this.ServiceStatusRow($r('app.string.media_services_label'), this.mediaLabel(),
            this.mediaStatusState())
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: 14, right: 14 })
          this.ServiceStatusRow('Taildrop', this.taildropLabel(), this.taildropStatusState())
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: 14, right: 14 })
          this.ServiceStatusRow('LocalSend', this.localSendLabel(), this.localSendStatusState())
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: 14, right: 14 })
          this.ServiceStatusRow('Taildrive', this.taildriveLabel(), this.taildriveStatusState())

          if (this.hasServiceActions()) {
            Divider()
              .color($r('sys.color.comp_divider'))
            Column({ space: 6 }) {
              Row({ space: 6 }) {
                if (this.sunshineAvailable) {
                  this.CompactAction($r('sys.symbol.rectangle_on_rectangle'),
                    $r('app.string.device_detail_remote_desktop_title'), this.sunshineLaunching,
                    this.onOpenStream)
                }
                if (this.mediaServiceCount > 0) {
                  this.CompactAction($r('sys.symbol.video'),
                    $r('app.string.device_detail_media_title'), this.mediaLaunching,
                    this.onOpenMedia)
                }
              }
              .width('100%')

              Row({ space: 6 }) {
                if (this.hasFileTransferAction()) {
                  this.CompactAction($r('sys.symbol.doc'),
                    $r('app.string.device_detail_transfer_title'), false,
                    this.onOpenFileTransfer)
                }
                if (this.online && this.remoteFilesEnabled) {
                  this.CompactAction($r('sys.symbol.folder'),
                    $r('app.string.device_detail_remote_files_title'), false,
                    this.onOpenRemoteFiles)
                }
              }
              .width('100%')
            }
            .width('100%')
            .padding(6)
          }
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(16)
        .clip(true)

        this.SectionTitle($r('app.string.device_detail_network_title'))
        Column({ space: 0 }) {
          this.InfoRow($r('app.string.device_connection_path'), this.pathLabel(), false)
          if (this.tailscaleAddress.length > 0) {
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: 14, right: 14 })
            this.CopyInfoRow($r('app.string.network_sheet_local_address'), this.tailscaleAddress,
              this.onCopyIp)
          }
          if (this.exitNodeCapable) {
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: 14, right: 14 })
            this.InfoRow($r('app.string.exit_node_title'),
              $r('app.string.device_detail_exit_node_available'), false)
          }
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(16)
        .clip(true)

        Blank()
          .width('100%')
          .height(16)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 4, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .nestedScroll({
      // Keep the half-modal detent/title fixed while the detail page scrolls.
      // The sheet can still take over once the content reaches its edge.
      scrollForward: NestedScrollMode.SELF_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    .align(Alignment.TopStart)
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
