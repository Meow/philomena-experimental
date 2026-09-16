/* eslint-disable camelcase -- Media JSON uses the context field names. */
import { bindImageTarget, selectVersion, pickAndResize, ImageTargetElement } from '../image-expansion';
import store from '../utils/store';
import { fireEvent } from '@testing-library/dom';
import { $ } from '../utils/dom';

describe('image-expansion', () => {
  let originalClientWidth: number;
  let originalClientHeight: number;
  let originalDevicePixelRatio: number;

  beforeEach(() => {
    // Save original values
    originalClientWidth = document.documentElement.clientWidth;
    originalClientHeight = document.documentElement.clientHeight;
    originalDevicePixelRatio = window.devicePixelRatio;

    // Set default viewport dimensions
    Object.defineProperty(document.documentElement, 'clientWidth', {
      writable: true,
      configurable: true,
      value: 1920,
    });
    Object.defineProperty(document.documentElement, 'clientHeight', {
      writable: true,
      configurable: true,
      value: 1080,
    });

    // Clear store
    vi.spyOn(store, 'get').mockReturnValue(null);
  });

  afterEach(() => {
    // Restore original values
    Object.defineProperty(document.documentElement, 'clientWidth', {
      writable: true,
      configurable: true,
      value: originalClientWidth,
    });
    Object.defineProperty(document.documentElement, 'clientHeight', {
      writable: true,
      configurable: true,
      value: originalClientHeight,
    });
    Object.defineProperty(window, 'devicePixelRatio', {
      writable: true,
      configurable: true,
      value: originalDevicePixelRatio,
    });
    vi.restoreAllMocks();
  });

  describe('selectVersion', () => {
    it('should return "tall" for comic-sized images on wide viewports', () => {
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 1280,
      });
      Object.defineProperty(document.documentElement, 'clientHeight', {
        writable: true,
        configurable: true,
        value: 1024,
      });

      const result = selectVersion(400, 3000, 1000000, 'image/png');
      expect(result).toBe('tall');
    });

    it('should return "medium" when viewport is between small and medium', () => {
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 640,
      });
      Object.defineProperty(document.documentElement, 'clientHeight', {
        writable: true,
        configurable: true,
        value: 480,
      });

      const result = selectVersion(1920, 1080, 1000000, 'image/png');
      expect(result).toBe('medium');
    });

    it('should return "full" when viewport is larger than all versions and size is reasonable', () => {
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 1920,
      });
      Object.defineProperty(document.documentElement, 'clientHeight', {
        writable: true,
        configurable: true,
        value: 1080,
      });

      const result = selectVersion(2000, 1500, 1000000, 'image/png');
      expect(result).toBe('full');
    });

    it('should return "large" when viewport is larger but file size exceeds limit', () => {
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 1920,
      });
      Object.defineProperty(document.documentElement, 'clientHeight', {
        writable: true,
        configurable: true,
        value: 1080,
      });

      const result = selectVersion(2000, 1500, 30_000_000, 'image/png');
      expect(result).toBe('large');
    });

    it('should return "full" for video/webm regardless of file size', () => {
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 1920,
      });
      Object.defineProperty(document.documentElement, 'clientHeight', {
        writable: true,
        configurable: true,
        value: 1080,
      });

      const result = selectVersion(2000, 1500, 50_000_000, 'video/webm');
      expect(result).toBe('full');
    });

    it('should scale viewport by devicePixelRatio when serve_hidpi is enabled', () => {
      Object.defineProperty(window, 'devicePixelRatio', {
        writable: true,
        configurable: true,
        value: 2,
      });
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 640,
      });
      Object.defineProperty(document.documentElement, 'clientHeight', {
        writable: true,
        configurable: true,
        value: 480,
      });

      vi.spyOn(store, 'get').mockReturnValue(true);

      // With 2x DPR, effective viewport is 1280x960, so it should pick large
      const result = selectVersion(1920, 1080, 1000000, 'image/png');
      expect(result).toBe('large');
    });

    it('should handle missing devicePixelRatio', () => {
      Object.defineProperty(window, 'devicePixelRatio', {
        writable: true,
        configurable: true,
        value: undefined,
      });
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 640,
      });
      Object.defineProperty(document.documentElement, 'clientHeight', {
        writable: true,
        configurable: true,
        value: 480,
      });

      vi.spyOn(store, 'get').mockReturnValue(true);

      const result = selectVersion(1920, 1080, 1000000, 'image/png');
      expect(result).toBe('medium');
    });

    it('should select version based on height when height constraint is reached first', () => {
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 1920,
      });
      Object.defineProperty(document.documentElement, 'clientHeight', {
        writable: true,
        configurable: true,
        value: 400,
      });

      const result = selectVersion(800, 1200, 1000000, 'image/png');
      expect(result).toBe('medium');
    });
  });

  describe('pickAndResize', () => {
    const sizes = ['full', 'tall', 'large', 'medium', 'small', 'thumb', 'thumb_small', 'thumb_tiny'];
    const version = (uri: string) => ({ uri, width: 1920, height: 1080 });

    function createImageTarget(type: 'none' | 'gif' | 'webm', scaled = 'false'): ImageTargetElement {
      const elem = document.createElement('div');
      elem.className = 'image-target';
      Object.assign(elem.dataset, {
        width: '1920',
        height: '1080',
        imageSize: '1000000',
        mimeType: { webm: 'video/webm', gif: 'image/gif', none: 'image/png' }[type],
        scaled,
        uris: JSON.stringify(Object.fromEntries(sizes.map(size => [size, `/primary/${size}?token=abc`]))),
        supplements: JSON.stringify(
          {
            none: { type: 'none' },
            gif: {
              type: 'gif',
              static_preview: version('/poster'),
              webm: version('/gif-webm?token=1'),
              mp4: version('/gif-mp4?token=2'),
            },
            webm: {
              type: 'webm',
              static_preview: version('/poster'),
              mp4: version('/fallback/full?token=2'),
              mp4_thumbnails: Object.fromEntries(sizes.map(size => [size, version(`/fallback/${size}?token=2`)])),
              gif_previews: Object.fromEntries(
                ['thumb', 'thumb_small', 'thumb_tiny'].map(size => [size, version(`/preview/${size}`)]),
              ),
            },
          }[type],
        ),
      });
      return elem as ImageTargetElement;
    }

    it.each(['none', 'gif'] as const)('renders %s images using opaque URLs', type => {
      const elem = createImageTarget(type);
      pickAndResize(elem);
      expect($('img', elem)?.getAttribute('src')).toBe('/primary/full?token=abc');
      expect($('img', elem)?.getAttribute('width')).toBe('1920');
      const picture = $('picture', elem);
      pickAndResize(elem);
      expect($('picture', elem)).toBe(picture);
    });

    it.each(['true', 'partscaled'])('applies the %s scaling class', scaled => {
      const elem = createImageTarget('none', scaled);
      pickAndResize(elem);
      expect($('img', elem)?.className).toBe(scaled === 'true' ? 'image-scaled' : 'image-partscaled');
    });

    it('uses the selected image size', () => {
      Object.defineProperty(document.documentElement, 'clientWidth', { value: 640 });
      const elem = createImageTarget('none', 'true');
      pickAndResize(elem);
      expect($('img', elem)?.getAttribute('src')).toBe('/primary/medium?token=abc');
    });

    it.each(['true', 'partscaled', 'false'])('uses explicit WebM and MP4 sources when scaled=%s', scaled => {
      Object.defineProperty(document.documentElement, 'clientWidth', { value: 640 });
      const elem = createImageTarget('webm', scaled);
      pickAndResize(elem);
      const size = scaled === 'true' ? 'medium' : 'full';
      const sources = elem.querySelectorAll('source');
      expect(sources[0].getAttribute('src')).toBe(`/primary/${size}?token=abc`);
      expect(sources[1].getAttribute('src')).toBe(`/fallback/${size}?token=2`);
      const video = $('video', elem);
      pickAndResize(elem);
      expect($('video', elem)).toBe(video);
    });

    it('plays a full GIF as video when requested and returns to an image when scaled', () => {
      vi.spyOn(store, 'get').mockImplementation(key => key === 'serve_webm');
      const elem = createImageTarget('gif');
      pickAndResize(elem);
      expect(elem.querySelectorAll('source')[0].getAttribute('src')).toBe('/gif-webm?token=1');
      expect(elem.querySelectorAll('source')[1].getAttribute('src')).toBe('/gif-mp4?token=2');
      expect($('video', elem)?.getAttribute('width')).toBe('1920');
      expect(elem).toHaveClass('full-height');
      const video = $('video', elem);
      pickAndResize(elem);
      expect($('video', elem)).toBe(video);

      Object.defineProperty(document.documentElement, 'clientWidth', { value: 640 });
      elem.dataset.scaled = 'true';
      pickAndResize(elem);
      expect($('img', elem)?.getAttribute('src')).toBe('/primary/medium?token=abc');
      expect(elem).not.toHaveClass('full-height');
    });

    it('refreshes video sources if the MP4 supplement changes', () => {
      const elem = createImageTarget('webm');
      pickAndResize(elem);
      const first = $('video', elem);
      elem.querySelectorAll('source')[1].src = '/outdated';
      pickAndResize(elem);
      expect($('video', elem)).not.toBe(first);
      expect(elem.querySelectorAll('source')[1].getAttribute('src')).toBe('/fallback/full?token=2');
    });

    it.each([true, false])('respects unmute_videos=%s', unmute => {
      vi.spyOn(store, 'get').mockImplementation(key => key === 'unmute_videos' && unmute);
      const elem = createImageTarget('webm');
      pickAndResize(elem);
      expect($('video', elem)?.hasAttribute('muted')).toBe(!unmute);
    });

    it.each([true, false])('only autoplays visible videos (hidden=%s)', hidden => {
      const elem = createImageTarget('webm');
      elem.classList.toggle('hidden', hidden);
      pickAndResize(elem);
      expect($('video', elem)?.hasAttribute('autoplay')).toBe(!hidden);
    });
  });

  describe('bindImageTarget', () => {
    function createImageTarget(mimeType: string): HTMLElement {
      const elem = document.createElement('div');
      elem.className = 'image-target';
      elem.dataset.width = '1920';
      elem.dataset.height = '1080';
      elem.dataset.imageSize = '1000000';
      elem.dataset.mimeType = mimeType;
      elem.dataset.supplements = JSON.stringify({ type: 'none' });
      elem.dataset.scaled = 'true';
      elem.dataset.uris = JSON.stringify({
        full: '/images/full.png',
        large: '/images/large.png',
        medium: '/images/medium.png',
        small: '/images/small.png',
      });
      return elem;
    }

    it('should toggle scaled state on click for images', () => {
      const elem = createImageTarget('image/png');
      document.body.appendChild(elem);

      bindImageTarget();

      expect(elem.dataset.scaled).toBe('true');

      fireEvent.click(elem);
      expect(elem.dataset.scaled).toBe('partscaled');

      fireEvent.click(elem);
      expect(elem.dataset.scaled).toBe('false');

      fireEvent.click(elem);
      expect(elem.dataset.scaled).toBe('true');

      document.body.removeChild(elem);
    });

    it('should not bind click handler for video/webm', () => {
      const elem = createImageTarget('video/webm');
      elem.dataset.supplements = JSON.stringify({ type: 'webm', mp4_thumbnails: { full: { uri: '/fallback' } } });
      elem.dataset.uris = JSON.stringify({
        full: '/videos/video.webm',
      });
      document.body.appendChild(elem);

      bindImageTarget();

      const initialScaled = elem.dataset.scaled;
      fireEvent.click(elem);

      // Should not change because click handler should not be bound
      expect(elem.dataset.scaled).toBe(initialScaled);

      document.body.removeChild(elem);
    });

    it('should re-render image on window resize', () => {
      const elem = createImageTarget('image/png');
      document.body.appendChild(elem);

      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 640,
      });

      bindImageTarget();

      expect(elem.innerHTML).toContain('medium.png');

      // Change viewport size
      Object.defineProperty(document.documentElement, 'clientWidth', {
        writable: true,
        configurable: true,
        value: 1100,
      });

      fireEvent(window, new Event('resize'));

      // Should now pick a larger version (1100 is larger than medium 800 but smaller than large 1280)
      expect(elem.innerHTML).toContain('large.png');

      document.body.removeChild(elem);
    });
  });
});
