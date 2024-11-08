package com.silbinarywolf.deskbreaker;

import org.libsdl.app.SDLActivity;

/**
 * A sample wrapper class that just calls SDLActivity
 */
public class DeskBreakerSDLActivity extends SDLActivity {
    /**
     * This method is called by SDL before loading the native shared libraries.
     * It can be overridden to provide names of shared libraries to be loaded.
     * The default implementation returns the defaults. It never returns null.
     * An array returned by a new implementation must at least contain "SDL3".
     * Also keep in mind that the order the libraries are loaded may matter.
     * @return names of shared libraries to be loaded (e.g. "SDL3", "main").
     */
    // @Override
    // protected String[] getLibraries() {
    //     return new String[] {
    //         "SDL3",
    //         // "SDL3_image",
    //         // "SDL3_mixer",
    //         // "SDL3_net",
    //         // "SDL3_ttf",
    //         "main"
    //     };
    // }
}
